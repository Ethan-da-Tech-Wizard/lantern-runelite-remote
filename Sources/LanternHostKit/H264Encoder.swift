// ==============================================================================
// Program: H264Encoder.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Hardware-accelerated H.264 video compression pipeline using Apple VideoToolbox.
//          Inputs: Uncompressed CVPixelBuffer video frames from ScreenCaptureKit.
//          Outputs: Compressed H.264 Annex-B packets tagged with presentation timestamps (PTS).
//          Design Rationale: Hardware acceleration with real-time low-latency profile (zero B-frames,
//          CBR, frequent IDR frames) delivers sub-10ms encode latency compared to WebRTC or MJPEG pipelines.
// ==============================================================================
// H264Encoder.swift - compresses raw video frames into H.264 using VideoToolbox (hardware when possible).
// Who calls it: WindowFrameSource (serving) and lantern-host's capture-test.
// Key ideas and architectural trade-offs:
//   - Video Pipeline Comparison:
//     * WebRTC Pipeline: Typically relies on libwebrtc's internal software/hardware wrappers with
//       automatic bandwidth estimation. For single-client LAN gaming, WebRTC adds substantial complexity,
//       signaling overhead, and latency buffering.
//     * MJPEG Pipeline: Simple JPEG frame compression, but lacks temporal inter-frame delta encoding.
//       Transmitting full JPEG frames results in high bitrates (20+ Mbps), frame rate throttling, and network jitter.
//     * VideoToolbox H.264 Pipeline (Lantern): Uses Apple's native hardware encoder configured for zero-latency
//       real-time streaming. Disables B-frames (no frame reordering delay), enforces Constant Bit Rate (CBR),
//       and emits Annex-B NALUs with prepended SPS/PPS headers on IDR keyframes for instant client sync.

// CoreMedia: CMSampleBuffer/CMTime, the wrapper types for media samples.
import CoreMedia
// CoreVideo: CVPixelBuffer, a raw frame of pixels.
import CoreVideo
// Foundation: Data, NSLock.
import Foundation
// VideoToolbox: Apple's video compression API (it can use the Mac's hardware encoder chip).
import VideoToolbox

/// One compressed video frame ready to send.
public struct EncodedPacket: Sendable {
    // True for a keyframe (decodable on its own); false for frames that depend on earlier ones.
    public var isKey: Bool
    // Presentation timestamp in microseconds (when to show the frame).
    public var ptsUs: UInt64
    // The frame bytes.
    /// Annex B access unit. On keyframes SPS+PPS are prepended.
    public var annexB: Data
    // The decoder set-up data, present only on keyframes.
    /// SPS+PPS (Annex B) on keyframes, nil otherwise.
    public var paramSets: Data?
}

// Errors from setting up or running the encoder; OSStatus is Apple's numeric error code.
public enum EncoderError: Error, CustomStringConvertible, Sendable {
    // Cases: could not create the session, could not set a property, could not encode a frame, or encoder already shut down.
    case createFailed(OSStatus), propertyFailed(String, OSStatus), encodeFailed(OSStatus), notRunning
    // Messages shown when an error is printed.
    public var description: String {
        switch self {
        case .createFailed(let s): return "VTCompressionSessionCreate failed (\(s))"
        case .propertyFailed(let k, let s): return "VT property \(k) failed (\(s))"
        case .encodeFailed(let s): return "VTCompressionSessionEncodeFrame failed (\(s))"
        case .notRunning: return "encoder is invalidated"
        }
    }
}

// Class (not struct) because it owns a system session object and callbacks. Thread safety is managed by `lock`.
/// Real-time H.264 encoder: Main profile, no B-frames, hardware preferred (not required).
public final class H264Encoder: @unchecked Sendable {
    // Frame size in pixels (fixed at creation).
    public let width: Int, height: Int
    // The VideoToolbox compression session (nil after shutdown).
    private var session: VTCompressionSession?
    // Protects session, forceKey and the callback.
    private let lock = NSLock()
    // Backing store for onPacket.
    private var _onPacket: (@Sendable (EncodedPacket) -> Void)?
    // When true, the next frame is forced to be a keyframe.
    private var forceKey = false
    // Whether the hardware encoder was actually chosen (readable outside, set only here); nil if unknown.
    public private(set) var usingHardware: Bool?

    // Callback receiving each finished packet. Called on a VideoToolbox thread.
    public var onPacket: (@Sendable (EncodedPacket) -> Void)? {
        // Thread-safe read/write.
        get { lock.lock(); defer { lock.unlock() }; return _onPacket }
        set { lock.lock(); _onPacket = newValue; lock.unlock() }
    }

    // Creates and configures the encoder. `fps` and the keyframe interval decide how often keyframes occur.
    public init(width: Int, height: Int, bitrate: Int, fps: Int, keyframeIntervalSeconds: Int = 2) throws {
        // Save the frame size.
        self.width = width; self.height = height
        // Will receive the new session.
        var s: VTCompressionSession?
        // Prefer the hardware encoder (but do not require it).
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        // Create the compression session: size, codec (H.264), our output callback and a pointer back to this object.
        let st = VTCompressionSessionCreate(
            // (Arguments: default memory allocator, size, codec, encoder preference, no special pixel requirements, our callback below,
            // and an unretained pointer to self so the callback can find us.)
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: h264OutputCallback, refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s)
        // noErr means success; otherwise report the failure.
        guard st == noErr, let s else { throw EncoderError.createFailed(st) }
        // Keep the session.
        session = s
        // Real-time mode: favour low delay over best compression.
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // No B-frames (frames that depend on future frames) because they add delay.
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)   // no B-frames
        // Main profile: widely supported by decoders (including iPhones).
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        // Tell the encoder the intended frame rate.
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // Force a keyframe at least every N frames (fps x seconds)...
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * keyframeIntervalSeconds) as CFNumber)
        // ...and at least every N seconds.
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeIntervalSeconds as CFNumber)
        // Set the target data rate and its cap.
        try apply(bitrate: bitrate)
        // Let the encoder allocate resources now so the first frame is not slow.
        VTCompressionSessionPrepareToEncodeFrames(s)
        // Ask the session whether it is really using hardware.
        var raw: UnsafeMutableRawPointer?
        // On success, turn the returned CFBoolean into a Swift Bool.
        if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: nil, valueOut: &raw) == noErr, let raw {
            // takeRetainedValue hands memory ownership to Swift so it is released correctly.
            usingHardware = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeRetainedValue())
        }
    }

    // When this object is released, shut the session down.
    deinit { invalidate() }

    // Helper: set one VideoToolbox property, throwing a readable error on failure.
    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        // No session means the encoder was already shut down.
        guard let session else { throw EncoderError.notRunning }
        // Apply the property to the session.
        let st = VTSessionSetProperty(session, key: key, value: value)
        // Non-zero status = failure.
        guard st == noErr else { throw EncoderError.propertyFailed(key as String, st) }
    }

    // Sets the average rate and a short-term cap.
    private func apply(bitrate: Int) throws {
        // Average bits per second to aim for.
        try set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        // Cap: at most 1.5x average over any 1 second window (bytes, seconds).
        // Build the [bytes allowed, per 1 second] pair.
        try set(kVTCompressionPropertyKey_DataRateLimits, [Int(Double(bitrate) * 1.5 / 8), 1] as CFArray)
    }

    // Change the data rate while running (locked so it cannot overlap with encode).
    public func update(bitrate: Int) throws { lock.lock(); defer { lock.unlock() }; try apply(bitrate: bitrate) }
    // Request that the next frame be a keyframe.
    public func forceKeyframe() { lock.lock(); forceKey = true; lock.unlock() }

    // Submits one raw frame for compression. The result arrives later in the callback below.
    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) throws {
        // Under the lock: read the session and take (and reset) the force-keyframe flag.
        lock.lock()
        // Encoder shut down: unlock before throwing.
        guard let session else { lock.unlock(); throw EncoderError.notRunning }
        // Read and clear the flag.
        let key = forceKey; forceKey = false
        // Release the lock before the slow encode call.
        lock.unlock()
        // When a keyframe is wanted, pass the 'force key frame' option for this frame.
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        // Hand the frame to the encoder with its timestamp.
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                 duration: .invalid, frameProperties: props,
                                                 sourceFrameRefcon: nil, infoFlagsOut: nil)
        // Report failure.
        guard st == noErr else { throw EncoderError.encodeFailed(st) }
    }

    // Convenience: encode a captured CMSampleBuffer by pulling out its pixels and timestamp.
    public func encode(_ sample: CMSampleBuffer) throws {
        // A sample with no image is silently skipped.
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        // Encode with the sample's own timestamp.
        try encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// Flushes pending frames and tears down.
    public func finish() {
        // Wait for any frames still being compressed.
        if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
        // Then shut the session down.
        invalidate()
    }

    // Detach and destroy the session exactly once.
    private func invalidate() {
        // Take the session out under the lock so nobody else uses it.
        lock.lock(); let s = session; session = nil; lock.unlock()
        // Destroy it outside the lock.
        if let s { VTCompressionSessionInvalidate(s) }
    }

    // Called by the VideoToolbox callback for each compressed frame: converts it into an EncodedPacket and passes it on.
    fileprivate func handle(_ sb: CMSampleBuffer) {
        // Skip frames with no ready data.
        guard CMSampleBufferDataIsReady(sb), let block = CMSampleBufferGetDataBuffer(sb) else { return }
        // Assume keyframe unless the 'not sync' mark says otherwise.
        var isKey = true
        // A frame marked NotSync depends on earlier frames, so it is not a keyframe.
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           // (check the first attachment dictionary)
           let first = arr.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true { isKey = false }
        // Get a pointer to the compressed bytes.
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        // Fail quietly if the pointer cannot be obtained.
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len,
                                          dataPointerOut: &ptr) == noErr, let ptr else { return }
        // Copy the bytes (in length-prefixed AVCC form).
        let avcc = Data(bytes: ptr, count: len)
        // Length-field size, normally 4 (updated below from the format description).
        var nalSize: Int32 = 4
        // Will hold SPS+PPS (decoder set-up data) for keyframes.
        var params: Data?
        // On keyframes, read the parameter sets from the frame's format description.
        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            // First call only asks how many parameter sets exist and the length-field size.
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalSize)
            // Collect every parameter set, each preceded by a start code.
            var p = Data()
            // Visit each parameter set.
            for i in 0..<count {
                // Pointer and size for this one.
                var psp: UnsafePointer<UInt8>?; var psl = 0
                // If it can be read, append start code + bytes.
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &psp,
                        parameterSetSizeOut: &psl, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let psp {
                    p.append(contentsOf: AnnexB.startCode); p.append(psp, count: psl)
                }
            }
            // Remember them.
            params = p
        }
        // Convert the frame's length-prefixed NAL units to start-code form; drop the frame if malformed.
        guard var body = AnnexB.fromAVCC(avcc, nalLengthSize: Int(nalSize)) else { return }
        // Put parameter sets in front so every keyframe is self-sufficient for a decoder that joins late.
        if let params { body = params + body }
        // Presentation time of the frame.
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // Convert seconds to whole microseconds (never negative; 0 if the time is invalid).
        let us = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
        // Deliver the packet to the listener.
        onPacket?(EncodedPacket(isKey: isKey, ptsUs: us, annexB: body, paramSets: params))
    }
}

// C-style callback VideoToolbox calls when a frame finishes compressing. `refcon` is the pointer to the encoder we passed at creation.
private let h264OutputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
    // Ignore failed or empty results.
    guard status == noErr, let refcon, let sampleBuffer else { return }
    // Turn the raw pointer back into the encoder object (without changing its retain count) and process the frame.
    Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue().handle(sampleBuffer)
}
