// ==============================================================================
// Program: H264Display.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Hardware H.264 video decoding and display engine using AVSampleBufferDisplayLayer.
//          Inputs: Compressed H.264 Annex-B packets received from network transport.
//          Outputs: CMSampleBuffer structures fed to hardware display layer for on-screen presentation.
//          Design Rationale: Directly feeds Apple hardware decoder without copying through CPU textures,
//          achieving minimal latency compared to WebRTC or MJPEG pipelines.
// ==============================================================================
// H264Display.swift
//
// PURPOSE: Takes compressed H.264 video frames (Annex B format) and shows them on screen.
//
// WHO CALLS IT: A transport (NetTransport or DemoTransport) calls `DisplayLayerSink.enqueue`
// for each frame. StreamView/VideoView owns the sink and adds its `layer` to the screen.
//
// KEY IDEAS (video decoding and pipeline architecture):
//   - Video Pipeline Architecture Trade-Offs (WebRTC vs MJPEG vs H.264 VideoToolbox):
//     * WebRTC Video Pipeline: Designed for multi-party conferencing over variable internet connections.
//       While WebRTC handles jitter buffering and RTCP feedback, it introduces 50-100ms buffering latency,
//       demands significant memory/battery footprint, and requires complex SDP/ICE network negotiation.
//     * Motion JPEG (MJPEG) Pipeline: Treats video as independent JPEG snapshots sent over HTTP multipart.
//       While simple to decode, MJPEG lacks temporal motion vector compression, creating extreme network
//       bandwidth demands (15-30 Mbps) and resulting in buffer bloat and dropped frames over Wi-Fi.
//     * Hardware H.264 VideoToolbox Pipeline (Lantern): Uses single-frame Annex B NALUs transported over
//       custom authenticated UDP (Noise Protocol). Packets directly feed Apple's low-overhead hardware
//       decoder via AVSampleBufferDisplayLayer, maintaining true real-time sub-15ms display latency.
//   - H.264 is a temporal compression format. An IDR "key frame" is a self-contained intra-coded picture;
//     subsequent P-frames store only pixel delta residuals. Decoding must start at a key frame.
//   - Annex B Framing vs AVCC Format:
//     * Annex B uses start codes (00 00 01 or 00 00 00 01) to delimit NAL units over raw byte streams.
//     * Apple's VideoToolbox / AVSampleBufferDisplayLayer expects AVCC format: each NAL unit is preceded
//       by a 4-byte big-endian length header. The helper methods below perform fast in-place conversion.
//   - SPS (Sequence Parameter Set) & PPS (Picture Parameter Set):
//     * Small metadata NAL units defining resolution, profile, and macroblock scaling.
//     * Used to construct `CMVideoFormatDescription`, configuring the hardware decoder before sample submission.
//   - Hardware Decoding via `AVSampleBufferDisplayLayer`:
//     * Wraps compressed AVCC frames in `CMSampleBuffer` objects submitted directly to the GPU/VPU layer.
//     * Decoding and presentation occur asynchronously off the main thread, keeping SwiftUI UI responsive.

import Foundation
import AVFoundation
import CoreMedia

/// Annex B parsing + CMSampleBuffer construction. Pure functions, no UI.
enum H264 {
    /// Split Annex B into NAL units (start codes removed).
    static func nalUnits(_ d: Data) -> [Data] {
        // Copy to a byte array so we can index it quickly.
        let b = [UInt8](d)
        // Positions of each start code and the first byte after it.
        var starts: [(sc: Int, nal: Int)] = []
        // Scan position.
        var i = 0
        // Look at every 3-byte window.
        while i + 3 <= b.count {
            // Found the 3-byte start code 00 00 01: remember it and skip past it.
            if b[i] == 0, b[i+1] == 0, b[i+2] == 1 { starts.append((i, i + 3)); i += 3 }
            // Not a start code: move one byte forward.
            else { i += 1 }
        }
        // The NAL units we will return.
        var out: [Data] = []
        // Each NAL runs from after its start code up to the next start code (or the end of the data).
        for (k, s) in starts.enumerated() {
            // End position of this NAL.
            var end = k + 1 < starts.count ? starts[k+1].sc : b.count
            while end > s.nal, b[end-1] == 0 { end -= 1 }   // trailing zero (4-byte start code / padding)
            // Skip empty NALs.
            if end > s.nal { out.append(Data(b[s.nal..<end])) }
        }
        // The NAL units, without start codes.
        return out
    }

    /// Builds the decoder's format description from the stream's SPS and PPS NAL units. nil if either is empty or invalid.
    static func formatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        guard !sps.isEmpty, !pps.isEmpty else { return nil }   // empty Data has a nil base address
        // Output slot, filled in by the call below.
        var fd: CMVideoFormatDescription?
        // Borrow raw memory pointers for both arrays so Core Media can read them (they are only valid inside these closures).
        let st: OSStatus = sps.withUnsafeBytes { sp in pps.withUnsafeBytes { pp in
            // Pointers to the two parameter sets.
            let ptrs = [sp.bindMemory(to: UInt8.self).baseAddress!, pp.bindMemory(to: UInt8.self).baseAddress!]
            // Their sizes in bytes.
            let sizes = [sps.count, pps.count]
            // 2 parameter sets; 4 = length-prefix size of each NAL in the frames we will build later.
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        } }
        // Success only when the status is noErr.
        return st == noErr ? fd : nil
    }

    /// AVCC sample (4-byte lengths) from slice NALs: builds a one-frame CMSampleBuffer for the display layer.
    static func sampleBuffer(nals: [Data], format: CMVideoFormatDescription, ptsUs: UInt64) -> CMSampleBuffer? {
        // Will hold the frame in AVCC layout.
        var avcc = Data()
        // Prefix each NAL with its length as 4 big-endian bytes, then the NAL itself.
        for n in nals {
            // Length as a 4-byte big-endian number.
            var len = UInt32(n.count).bigEndian
            // Append the 4 length bytes, then the NAL bytes.
            avcc.append(Data(bytes: &len, count: 4)); avcc.append(n)
        }
        // Nothing to show if there were no slice NALs.
        guard !avcc.isEmpty else { return nil }
        // A block buffer is Core Media's container for raw bytes.
        var block: CMBlockBuffer?
        // Make a block buffer of the right size, then copy our bytes into it; give up if either step fails.
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let bb = block,
              avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: avcc.count) }) == noErr
        else { return nil }
        // Timing: show time in microseconds (timescale 1,000,000); no duration or decode time.
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        // Size in bytes of the single sample.
        var size = avcc.count
        // Output slot for the finished sample buffer.
        var sb: CMSampleBuffer?
        // Combine the bytes, the format description and the timing into one ready-to-use sample buffer.
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sb) == noErr, let s = sb else { return nil }
        // Mark the sample 'display immediately' so the layer shows it as soon as it arrives instead of waiting for its timestamp.
        if let arr = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        // The finished frame.
        return s
    }
}

/// VideoSink that turns Annex B access units into sample buffers for an AVSampleBufferDisplayLayer.
/// Decoding is done by the display layer (hardware H.264). Thread-safe via a serial queue.
// `final` = no subclasses. Frames are processed on the serial queue `q` below.
final class DisplayLayerSink: VideoSink {
    /// The on-screen layer that decodes and draws the frames; added to the view's layer tree by VideoView.
    let layer = AVSampleBufferDisplayLayer()
    /// Serial queue: tasks run one at a time, in order, so the stream state needs no locks.
    private let q = DispatchQueue(label: "lantern.decode.q")
    /// Latest SPS and PPS NAL units seen.
    private var sps: Data?, pps: Data?
    /// Decoder description built from SPS+PPS; nil until both have been seen.
    private var format: CMVideoFormatDescription?
    /// True while we are waiting for a key frame (start of stream or after a problem).
    private var needKey = true
    /// Called on main with the video's pixel size when the format changes (for letterbox math).
    var onSize: ((CGSize) -> Void)?
    /// Called when decoding needs a key frame (the transport sends a .requestIDR control message).
    var onNeedKeyframe: (() -> Void)?
    /// How many frames have been handed to the display layer.
    private(set) var framesShown = 0

    // `.resizeAspect` keeps the picture's shape (black bars) instead of stretching it.
    init() { layer.videoGravity = .resizeAspect }

    /// Receives one frame; the work is moved onto the serial queue so the caller is never blocked.
    func enqueue(annexB: Data, isKey: Bool, ptsUs: UInt64) {
        // Everything inside runs on the serial queue.
        q.async { [self] in
            // The picture data (slice NALs) found in this frame.
            var slices: [Data] = []
            // Look at each NAL unit in the frame.
            for n in H264.nalUnits(annexB) {
                // The NAL type is the low 5 bits of its first byte.
                switch n.first.map({ $0 & 0x1f }) {
                // Type 7 = SPS. If it changed, store it and drop the old format description.
                case 7: if n != sps { sps = n; format = nil }
                // Type 8 = PPS. Same idea.
                case 8: if n != pps { pps = n; format = nil }
                // Types 1 and 5 = picture slices (5 is a key-frame slice): keep them for decoding.
                case 1, 5: slices.append(n)
                // Other NAL types are ignored.
                default: break
                }
            }
            // If we now have both parameter sets but no format yet, build it.
            if format == nil, let s = sps, let p = pps {
                // Create the decoder description.
                format = H264.formatDescription(sps: s, pps: p)
                // Read the video size from it.
                if let f = format {
                    // Width and height in pixels.
                    let d = CMVideoFormatDescriptionGetDimensions(f)
                    // Package the size.
                    let size = CGSize(width: Int(d.width), height: Int(d.height))
                    // Tell the UI on the main thread (for letterbox math).
                    DispatchQueue.main.async { self.onSize?(size) }
                }
            }
            // No format yet (SPS/PPS not seen): if this was not a key frame, ask for one; either way stop here.
            guard let f = format else { if isKey == false { needKeyframe() }; return }
            // Decoding cannot start on a delta frame: ask for a key frame and drop this frame.
            if needKey && !isKey { needKeyframe(); return }       // wait for a key frame
            // A key frame arrived: decoding may proceed.
            if isKey { needKey = false }
            // Convert to a sample buffer; if that fails, ask for a key frame.
            guard let sb = H264.sampleBuffer(nals: slices, format: f, ptsUs: ptsUs) else { needKeyframe(); return }
            // If the layer reported a decode error, clear it, drop this frame and ask for a key frame.
            if layer.status == .failed { layer.flush(); needKeyframe(); return }
            // Hand the frame to the display layer, which decodes and shows it.
            layer.enqueue(sb)
            // Count it.
            framesShown += 1
        }
    }

    /// Marks that we need a key frame and tells the owner (on main) so the network layer can request one.
    private func needKeyframe() {
        // Ignore all frames until a key frame arrives.
        needKey = true
        // Copy the callback so the main-queue block uses a stable value.
        let cb = onNeedKeyframe
        // Call back on the main thread.
        DispatchQueue.main.async { cb?() }
    }

    /// Forget the stream settings and clear the picture (used on reconnect or new config).
    func reset() {
        // Run on the serial queue so it cannot overlap with `enqueue`.
        q.async { [self] in
            // Forget SPS/PPS/format and wait for the next key frame.
            sps = nil; pps = nil; format = nil; needKey = true
            // Remove whatever picture is currently on the layer.
            layer.flushAndRemoveImage()
        }
    }
}
