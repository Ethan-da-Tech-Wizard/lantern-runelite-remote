// ==============================================================================
// Program: AnnexB.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: H.264 Annex B byte stream format utilities and NAL unit start-code delimiter parsers.
//          Inputs: Raw H.264 elementary streams or AVCC length-prefixed blocks.
//          Outputs: Formatted Annex B NAL units with 3-byte and 4-byte start code prefixes.
//          Design Rationale: Annex B framing allows streaming video decoders to regain frame
//          synchronization after packet drops without separate transport framing.
// ==============================================================================
// AnnexB.swift - converts H.264 NAL units between two framings (length-prefixed AVCC and start-code Annex B).
// Who calls it: H264Encoder (turns the encoder's output into the stream we send); tests also use nalUnits.
// Key ideas: pure functions with no system calls, so they are easy to test; malformed input returns nil.

// Foundation provides Data (a byte buffer).
import Foundation

// Background: H.264 video is a stream of NAL units (small chunks such as 'parameter sets' and 'picture slices').
// Apple's encoder gives them 'length-prefixed' (AVCC); network/decoder side wants 'start-code' framing (Annex B).
/// AVCC (length-prefixed) <-> Annex B helpers. Pure functions.
// Namespace only: all members are static pure functions (same input, same output, no side effects).
public enum AnnexB {
    // The 4-byte marker 00 00 00 01 that tells a decoder "a new NAL unit begins here".
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    // nalLengthSize is how many bytes hold each unit's length (the encoder normally uses 4).
    /// Converts length-prefixed NAL units to Annex B. Returns nil on malformed lengths.
    public static func fromAVCC(_ avcc: Data, nalLengthSize: Int = 4) -> Data? {
        // Only 1 to 4 byte lengths make sense; anything else is a caller error.
        guard (1...4).contains(nalLengthSize) else { return nil }
        // Copy to an array of bytes for easy indexing.
        let bytes = [UInt8](avcc)
        // `out` collects the converted stream; `i` is our read position.
        var out = Data(); var i = 0
        // Walk through the buffer one NAL unit at a time.
        while i < bytes.count {
            // Not enough bytes left to even read a length: the data is damaged, give up (nil).
            guard i + nalLengthSize <= bytes.count else { return nil }
            // Read the big-endian length: shift what we have left by 8 bits and add the next byte.
            var len = 0
            for k in 0..<nalLengthSize { len = (len << 8) | Int(bytes[i + k]) }
            // Step past the length field to the start of the NAL payload.
            i += nalLengthSize
            // A zero length, or one that runs past the end of the buffer, means malformed data.
            guard len > 0, i + len <= bytes.count else { return nil }
            // Write the start code, then the NAL bytes themselves.
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[i..<(i + len)])
            // Jump to the next unit's length field.
            i += len
        }
        // Done: all units converted.
        return out
    }

    /// Splits an Annex B stream into NAL units (without start codes).
    public static func nalUnits(_ data: Data) -> [Data] {
        // `starts` remembers where each start code is (position) and how long it is (3 or 4 bytes).
        let b = [UInt8](data); var starts: [(pos: Int, sc: Int)] = []; var i = 0
        // Scan byte by byte for 00 00 01 (3-byte code) or 00 00 00 01 (4-byte code).
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append((i, 3)); i += 3 }
            else if i + 4 <= b.count, b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, 4)); i += 4 }
            else { i += 1 }
        }
        // Each unit runs from just after its start code to just before the next start code (or the end).
        return starts.enumerated().map { n, s in
            // First byte after this unit's start code.
            let begin = s.pos + s.sc
            // Last byte is right before the next start code; the final unit goes to the end of the data.
            let end = n + 1 < starts.count ? starts[n + 1].pos : b.count
            // Copy that slice out as its own Data.
            return Data(b[begin..<end])
        }
    }

    /// The NAL type is the low 5 bits of the first byte (e.g. 5 = keyframe slice, 7 = SPS, 8 = PPS). nil if empty.
    // 0x1F is the bit mask for those low 5 bits.
    public static func nalType(_ nal: Data) -> UInt8? { nal.first.map { $0 & 0x1F } }
}
