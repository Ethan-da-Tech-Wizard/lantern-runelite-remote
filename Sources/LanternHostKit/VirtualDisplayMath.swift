// ==============================================================================
// Program: VirtualDisplayMath.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Geometric calculations for aspect ratios, scaling factors, and letterboxing for virtual displays.
//          Inputs: Display bounds, window aspect ratios, and device screen dimensions.
//          Outputs: Fitted viewport rectangles and letterbox offset coordinates.
//          Design Rationale: Ensures pixel-perfect alignment and prevents distortion when mapping mobile
//          screen aspects to desktop game viewports.
// ==============================================================================
// VirtualDisplayMath.swift - pure size/mode calculations and error types for the phone-shaped virtual display.
// Who calls it: VirtualDisplay.swift (which makes the real display from a spec).
// Key ideas: a 'virtual display' is a pretend monitor macOS believes exists; validating its size here,
// without touching the system, keeps the risky private-API code small.

// Foundation: basic types.
import Foundation

// A value type: once created it never changes. Equatable/Sendable so tests and threads can use it freely.
/// Pure size/mode math for the phone-shaped virtual display. No system calls.
public struct VirtualDisplaySpec: Equatable, Sendable {
    // Smallest allowed width or height in pixels.
    public static let minDimension = 320
    // Largest allowed width or height in pixels.
    public static let maxDimension = 8192
    // Highest refresh rate (frames per second) we accept.
    public static let maxRefresh = 120.0
    // `try!` is safe here: these constants are known to be valid, and a unit test would catch a mistake.
    /// iPhone landscape default (19.5:9).
    public static let phoneDefault = try! VirtualDisplaySpec(width: 2532, height: 1170, refresh: 60, hiDPI: true)

    // Width in real pixels.
    public let width: Int
    // Height in real pixels.
    public let height: Int
    // Refresh rate in Hz.
    public let refresh: Double
    // 'HiDPI' (Retina): each logical point is drawn with 2x2 pixels.
    public let hiDPI: Bool

    // The initializer validates everything and throws a clear error instead of building a bad spec.
    public init(width: Int, height: Int, refresh: Double = 60, hiDPI: Bool = true) throws {
        // Both dimensions must be inside the allowed range.
        guard (Self.minDimension...Self.maxDimension).contains(width),
              (Self.minDimension...Self.maxDimension).contains(height) else {
            throw VirtualDisplayError.invalidSize(width: width, height: height)
        }
        // Refresh must be at least 1 and at most the max.
        guard refresh >= 1, refresh <= Self.maxRefresh else { throw VirtualDisplayError.invalidRefresh(refresh) }
        // HiDPI needs even pixel counts so halving to points gives whole numbers.
        if hiDPI && (width % 2 != 0 || height % 2 != 0) { throw VirtualDisplayError.invalidSize(width: width, height: height) }
        // All checks passed; store the values.
        self.width = width; self.height = height; self.refresh = refresh; self.hiDPI = hiDPI
    }

    // Width divided by height (about 2.16 for the phone default).
    public var aspectRatio: Double { Double(width) / Double(height) }

    // Computed properties: no storage, calculated on demand.
    /// Logical (point) size: half the pixels when HiDPI, else equal.
    public var logicalWidth: Int { hiDPI ? width / 2 : width }
    // Same for height.
    public var logicalHeight: Int { hiDPI ? height / 2 : height }

    // A list of (width, height, refresh) tuples to register with the system.
    /// Modes to register: the native pixel mode, plus the logical mode when HiDPI.
    public var modes: [(width: Int, height: Int, refresh: Double)] {
        // Start with the full pixel mode.
        var m = [(width: width, height: height, refresh: refresh)]
        // With HiDPI also offer the half-size logical mode.
        if hiDPI { m.append((width: logicalWidth, height: logicalHeight, refresh: refresh)) }
        // Return the list.
        return m
    }

    // Pretend physical size, so macOS picks sensible scaling. 25.4 mm per inch.
    /// Physical size in mm for a nominal ~460 ppi phone-like density (descriptor needs one).
    public var sizeInMillimeters: (width: Double, height: Double) {
        // Assumed pixels per inch (phone-like density).
        let ppi = 460.0
        // pixels / pixels-per-inch = inches; times 25.4 = millimetres.
        return (Double(width) / ppi * 25.4, Double(height) / ppi * 25.4)
    }

    // True when the two specs' width/height ratios differ by no more than `tolerance`.
    /// Whether `other` has the same aspect ratio within tolerance.
    public func sameAspect(as other: VirtualDisplaySpec, tolerance: Double = 0.005) -> Bool {
        // abs() because we only care about the size of the difference, not its sign.
        abs(aspectRatio - other.aspectRatio) <= tolerance
    }

    // Build a bigger or smaller spec with the same shape.
    /// Larger same-ratio fallback mode (e.g. 3036x1404 for 2532x1170), rounded to even pixels.
    public func scaledSameRatio(width newWidth: Int) throws -> VirtualDisplaySpec {
        // Height that keeps the ratio, rounded to the nearest whole pixel.
        var h = Int((Double(newWidth) / aspectRatio).rounded())
        // Make it even (the % operator gives the remainder; odd means remainder 1).
        if h % 2 != 0 { h += 1 }
        // Re-run validation on the new size and return it.
        return try VirtualDisplaySpec(width: newWidth, height: h, refresh: refresh, hiDPI: hiDPI)
    }
}

// Everything that can go wrong creating a virtual display, each with a readable message.
public enum VirtualDisplayError: Error, Equatable, CustomStringConvertible {
    // Size out of range or odd for HiDPI.
    case invalidSize(width: Int, height: Int)
    // Refresh rate out of range.
    case invalidRefresh(Double)
    // The private macOS classes were not found or lack a needed method.
    case apiUnavailable(String)
    // macOS created nothing or returned an error.
    case creationFailed(String)
    // macOS refused the requested modes.
    case settingsRejected

    // The text shown when an error is printed.
    public var description: String {
        switch self {
        case .invalidSize(let w, let h): return "invalid virtual display size \(w)x\(h)"
        case .invalidRefresh(let r): return "invalid refresh rate \(r)"
        case .apiUnavailable(let s): return "CGVirtualDisplay private API unavailable: \(s)"
        case .creationFailed(let s): return "virtual display creation failed: \(s)"
        case .settingsRejected: return "virtual display rejected the mode settings"
        }
    }
}
