// Program: Lantern - DemoTransport.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Fake transport that makes a test video and logs input, for trying the app without a Mac.
//
// DemoTransport.swift
//
// PURPOSE: A fake, offline stand-in for the real network transport. It draws its own moving test
// picture, compresses it to H.264 with Apple's VideoToolbox, and feeds it to the same video sink that
// real video uses. This lets the app be tested without a Mac or a network.
//
// WHO CALLS IT: ClientModel creates it when the app is launched with a demo argument.
//
// KEY IDEAS:
//   - A Timer fires 15 times a second; each tick draws one frame into a pixel buffer, encodes it,
//     and the encoder's callback converts the result to Annex B and hands it to the sink.
//   - Real encoders output "AVCC" (length-prefixed) NAL units; the sink expects "Annex B" (start-code
//     separated), so `annexB(from:)` converts, adding SPS/PPS settings in front of key frames.
//   - Input events are accepted but thrown away: nothing is ever sent anywhere.

import Foundation
import VideoToolbox
import CoreVideo
import LanternCore

/// Offline stand-in for the real Net layer. Renders a synthetic moving frame, encodes it with
/// VideoToolbox H.264, and pushes Annex B through the same VideoSink path real video will use.
/// Frames come from a display timer only; input is just counted by the model (nothing is sent anywhere).
// `@MainActor`: runs on the main thread, as the SessionTransport protocol requires.
@MainActor
// `final` = no subclasses.
final class DemoTransport: SessionTransport {
    /// Set by the model; called when the state changes.
    var onState: ((TransportState) -> Void)?
    /// Where the finished frames go.
    var videoSink: VideoSink?
    /// Demo pairing is just a flag (no keys are involved).
    private(set) var isPaired = false
    /// Fires once per frame.
    private var timer: Timer?
    /// The H.264 encoder session.
    private var session: VTCompressionSession?
    /// Frame counter, also used as the time stamp.
    private var frameNo: Int64 = 0
    /// Picture width and height in pixels (720p).
    private let W = 1280, H = 720
    /// Result of the latest encode call (0 means success), kept for debugging.
    private(set) var lastEncodeStatus: OSStatus = 0

    /// Pretend to pair: just remember that we are paired.
    func pair(_ input: PairingInput, host: String) async throws { isPaired = true }

    /// Start the fake stream.
    func connect(host: String) async throws {
        // Tell the UI we are starting.
        onState?(.connecting)
        // Clear whatever the display was showing.
        videoSink?.reset()
        // Create the encoder; if that fails, report an error and stop.
        guard makeSession() else { onState?(.failed("Demo encoder unavailable")); return }
        // Start counting frames from zero so the first frame is a key frame.
        frameNo = 0
        // Now streaming.
        onState?(.streaming)
        // Stop any old timer first.
        timer?.invalidate()
        // Call `tick` 15 times per second.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            // The timer fires on the main thread, so we can tell Swift we are on the main actor.
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Input is dropped on purpose in demo mode.
    func send(_ event: InputEvent) { /* demo: dropped on purpose */ }
    /// Change the encoder's target bitrate (kbps converted to bits per second), if an encoder exists.
    func setBitrateHint(kbps: Int) {
        if let s = session { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: (kbps * 1000) as CFNumber) }
    }
    /// Stop the timer, shut down the encoder and report idle.
    func disconnect() {
        // Stop the frame timer.
        timer?.invalidate(); timer = nil
        // Release the encoder session.
        if let s = session { VTCompressionSessionInvalidate(s) }
        // Forget it.
        session = nil
        // Tell the UI we are idle.
        onState?(.idle)
    }
    /// Forget the pretend pairing.
    func forgetHost() { isPaired = false }

    /// Creates and configures the H.264 encoder. Returns false if it could not be created.
    private func makeSession() -> Bool {
        // Output slot for the session.
        var s: VTCompressionSession?
        // Ask VideoToolbox for an H.264 compression session at our picture size.
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        // Stop if creation failed; remember the error code.
        guard st == noErr, let sess = s else { lastEncodeStatus = st; return false }
        // Real-time mode: favour speed over best compression.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // No B-frames (frame reordering) so frames come out in order with low delay.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Baseline profile: the simplest H.264 flavour.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        // A key frame at least every 30 frames (every 2 seconds at 15 fps).
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        // Let the encoder allocate its resources now.
        VTCompressionSessionPrepareToEncodeFrames(sess)
        // Keep the session for later ticks.
        session = sess
        // Success.
        return true
    }

    /// One timer tick: draw a frame, encode it, and (through the callback) deliver it.
    private func tick() {
        // No encoder, nothing to do.
        guard let sess = session else { return }
        // Empty pixel buffer: a block of memory holding picture pixels.
        var pb: CVPixelBuffer?
        // 32-bit BGRA pixels, 1280x720, allowed to be drawn into with CPU memory access.
        CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        // If allocation failed, skip this frame.
        guard let buf = pb else { return }
        // Fill the buffer with the test pattern for this frame number.
        draw(buf, n: Int(frameNo))
        // Time stamp: frame number in 1/15 second units.
        let pts = CMTime(value: frameNo, timescale: 15)
        // Copy the sink to a local so the encoder callback can use it.
        let sink = videoSink
        // The first frame must be a key frame.
        let key = frameNo == 0
        // Ask the encoder to force a key frame for frame 0; otherwise no special options.
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        // Encode. The closure at the end is called when the compressed frame is ready (possibly on another thread).
        let st = VTCompressionSessionEncodeFrame(sess, imageBuffer: buf, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { status, _, sb in
            // Ignore failed frames.
            guard status == noErr, let sb else { return }
            // Convert to Annex B and send it to the sink with the time stamp in microseconds.
            if let (data, isKey) = DemoTransport.annexB(from: sb) {
                sink?.enqueue(annexB: data, isKey: isKey, ptsUs: UInt64(pts.seconds * 1_000_000))
            }
        }
        // Remember the encode status.
        lastEncodeStatus = st
        // Next frame number.
        frameNo += 1
    }

    /// Fills the pixel buffer with a moving test pattern: a bright vertical bar sweeping right, over a grid and gradient.
    private func draw(_ buf: CVPixelBuffer, n: Int) {
        // Lock the memory so the CPU can write to it.
        CVPixelBufferLockBaseAddress(buf, [])
        // Unlock automatically when this function ends, however it ends.
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        // Get a pointer to the first byte of pixels.
        guard let base = CVPixelBufferGetBaseAddress(buf)?.assumingMemoryBound(to: UInt8.self) else { return }
        // Bytes per row (may be larger than width*4 because of padding).
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        // Horizontal position of the bar; it moves 8 pixels each frame and wraps around.
        let bar = (n * 8) % W
        // For every row...
        for y in 0..<H {
            // ...pointer to the start of that row.
            let row = base + y * bpr
            // ...and for every pixel in the row.
            for x in 0..<W {
                // Each pixel is 4 bytes: blue, green, red, alpha.
                let p = row + x * 4
                // Is this pixel inside the bar (12 pixels either side of its centre)?
                let inBar = abs(x - bar) < 12
                // Is this pixel on a grid line (every 160 columns / 90 rows, 2 pixels thick)?
                let grid = (x % 160 < 2) || (y % 90 < 2)
                // Blue: white in the bar, otherwise a gradient down the picture.
                p[0] = inBar ? 255 : UInt8(truncatingIfNeeded: 40 + y * 120 / H)       // B
                // Green: bright on grid lines, otherwise a gradient across the picture.
                p[1] = grid ? 220 : UInt8(truncatingIfNeeded: 30 + x * 100 / W)        // G
                // Red: white in the bar, otherwise slowly changing with the frame number.
                p[2] = inBar ? 255 : UInt8(truncatingIfNeeded: 60 + (n * 2) % 100)     // R
                // Alpha: fully opaque.
                p[3] = 255
            }
        }
    }

    /// AVCC sample buffer -> Annex B (+ SPS/PPS on key frames).
    /// AVCC sample buffer -> Annex B (+ SPS/PPS on key frames).
    // `nonisolated`: callable from any thread (the encoder callback is not on the main thread).
    nonisolated static func annexB(from sb: CMSampleBuffer) -> (Data, Bool)? {
        // Need the data block and the format description (which holds SPS/PPS), else give up.
        guard let bb = CMSampleBufferGetDataBuffer(sb), let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        // Assume key frame unless the sample is flagged as not-sync.
        var isKey = true
        // Read the sample's attachment dictionary, if there is one.
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
            // A 'not sync' marker means a delta (non-key) frame.
            isKey = !CFDictionaryContainsKey(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        }
        // The 4-byte start code that separates NAL units in Annex B.
        let sc: [UInt8] = [0, 0, 0, 1]
        // Output bytes.
        var out = Data()
        // On key frames, put the SPS then PPS first so the decoder gets its settings.
        if isKey {
            // Parameter set 0 = SPS, 1 = PPS.
            for i in 0..<2 {
                // Pointer and size of the parameter set.
                var p: UnsafePointer<UInt8>?; var n = 0
                // Ask Core Media for it.
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                        parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p {
                    // Start code, then the parameter set bytes.
                    out.append(contentsOf: sc); out.append(p, count: n)
                }
            }
        }
        // Get a raw pointer to the compressed bytes in the block buffer.
        var len = 0; var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let ptr else { return nil }
        // View the bytes as a buffer we can index.
        let raw = UnsafeRawBufferPointer(start: ptr, count: len)
        // Read position.
        var o = 0
        // Each NAL is stored as a 4-byte big-endian length followed by that many bytes.
        while o + 4 <= len {
            // Build the length from 4 bytes.
            let l = Int(raw[o]) << 24 | Int(raw[o+1]) << 16 | Int(raw[o+2]) << 8 | Int(raw[o+3])
            // Step past the length field.
            o += 4
            // Stop if the length is zero or runs past the end (corrupt data).
            guard l > 0, o + l <= len else { break }
            // Annex B: start code then the NAL bytes.
            out.append(contentsOf: sc); out.append(contentsOf: raw[o..<(o + l)])
            // Move to the next NAL.
            o += l
        }
        // The converted data and whether it is a key frame.
        return (out, isKey)
    }
}
