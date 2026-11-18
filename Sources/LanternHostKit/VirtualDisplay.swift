// VirtualDisplay.swift - creates a 'virtual display' (a pretend monitor) using macOS's private CGVirtualDisplay API.
// Who calls it: nothing else in the app sources references it yet; it takes a VirtualDisplaySpec from VirtualDisplayMath.swift.
// Key ideas: the classes are private (undocumented), so they are found by name at run time and may disappear
// in a future macOS update. The display exists only as long as its handle is kept alive.

// Foundation: basic types and NSLock.
import Foundation
// CoreGraphics: CGDirectDisplayID (a display's number) and CGSize.
import CoreGraphics
// ObjectiveC runtime: lets us look up classes and call methods by NAME at run time (needed for private classes).
import ObjectiveC

// Background: macOS has a hidden, undocumented API (CGVirtualDisplay) that makes a pretend monitor.
// Because it is private, we do not link against it; we look the classes up by name while running.
// Usage pattern for the private CGVirtualDisplay classes (descriptor / mode / settings / display)
// follows what the open-source VoidDisplay (Apache-2.0) and DeskPad (MIT) projects demonstrate.
// This implementation is our own: classes are looked up at runtime, nothing is hard-linked,
// and no code is copied from those projects.

// A protocol so other code (and tests) can swap in a fake display maker.
/// Anything that can supply a display for capture (SCK matches by CGDirectDisplayID).
public protocol DisplayProvider {
    // Make a display of the given pixel size, refresh rate, HiDPI setting and name.
    func create(width: Int, height: Int, refresh: Double, hiDPI: Bool, name: String) throws -> VirtualDisplayHandle
    // Remove the display.
    func destroy()
}

// @unchecked Sendable: its fields never change after creation.
/// Handle to a live virtual display. Keep it alive: the display disappears when it is released.
public final class VirtualDisplayHandle: @unchecked Sendable {
    // The system's number for this display; ScreenCaptureKit finds the display by it.
    public let displayID: CGDirectDisplayID
    // The size/mode settings it was created with.
    public let spec: VirtualDisplaySpec
    // The display's name.
    public let name: String
    // The underlying system object. Holding this reference is what keeps the display alive.
    fileprivate let object: AnyObject
    // Only code in this file can make handles.
    init(displayID: CGDirectDisplayID, spec: VirtualDisplaySpec, name: String, object: AnyObject) {
        // Store each value.
        self.displayID = displayID; self.spec = spec; self.name = name; self.object = object
    }
}

// Creates the virtual display through the private classes; only one can exist at a time (see `handle`).
/// CGVirtualDisplay-backed provider. Private API: may break on macOS updates; fails with `apiUnavailable`.
public final class VirtualDisplay: DisplayProvider, @unchecked Sendable {
    // The current display, if any.
    private var handle: VirtualDisplayHandle?
    // Guards `handle` against two threads creating/destroying at once.
    private let lock = NSLock()
    // Nothing to set up.
    public init() {}

    // Handy check before trying to create a display.
    /// True when all four private classes resolve in this macOS build.
    public static var isAvailable: Bool { missingClasses().isEmpty }

    // Returns the names of classes this macOS version does not have (empty = all present).
    static func missingClasses() -> [String] {
        // The four private classes we need: descriptor (what the display is), settings, mode (one resolution) and the display itself.
        // NSClassFromString returns nil when a class does not exist.
        ["CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode", "CGVirtualDisplay"]
            .filter { NSClassFromString($0) == nil }
    }

    // Creates (or returns the existing) virtual display. Throws a VirtualDisplayError on any failure.
    public func create(width: Int, height: Int, refresh: Double = 60, hiDPI: Bool = true,
                       name: String = "Lantern Phone") throws -> VirtualDisplayHandle {
        // Validate the requested size first (no system calls yet).
        let spec = try VirtualDisplaySpec(width: width, height: height, refresh: refresh, hiDPI: hiDPI)
        // Make sure the private classes exist on this macOS.
        let missing = Self.missingClasses()
        // If any are missing, stop with a clear error instead of crashing.
        guard missing.isEmpty else { throw VirtualDisplayError.apiUnavailable("missing classes: \(missing.joined(separator: ", "))") }
        // From here on only one thread at a time.
        lock.lock(); defer { lock.unlock() }
        // A display already exists: return it (note: it keeps its original size).
        if let h = handle { return h }

        // Look up the classes by name and make sure they are normal Objective-C classes we can instantiate.
        guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let setCls = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let dispCls = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeCls = NSClassFromString("CGVirtualDisplayMode") else {
            // Could not use them: report API unavailable.
            throw VirtualDisplayError.apiUnavailable("class cast failed")
        }

        // Step 1: a descriptor describes the display's identity and size.
        let desc = descCls.init()
        // The pretend physical size in millimetres.
        let mm = spec.sizeInMillimeters
        // Fill in the descriptor's properties by name (key-value coding).
        try Self.set(desc, "name", name as NSString)
        try Self.set(desc, "maxPixelsWide", NSNumber(value: width))
        try Self.set(desc, "maxPixelsHigh", NSNumber(value: height))
        try Self.set(desc, "sizeInMillimeters", NSValue(size: CGSize(width: mm.width, height: mm.height)))
        // Made-up maker/product/serial numbers so macOS can tell this display apart.
        try Self.set(desc, "vendorID", NSNumber(value: 0x4C41))   // "LA", arbitrary
        try Self.set(desc, "productID", NSNumber(value: 0x0001))
        try Self.set(desc, "serialNum", NSNumber(value: 0x0001))
        // The queue macOS uses to call back about display events.
        try Self.set(desc, "queue", DispatchQueue.main)

        // Step 2: create the display object from the descriptor.
        guard let display = Self.makeDisplay(dispCls, desc) else {
            throw VirtualDisplayError.creationFailed("initWithDescriptor: returned nil")
        }

        // Step 3: settings choose the modes (resolutions) and HiDPI.
        let settings = setCls.init()
        // 1 = HiDPI (Retina) on, 0 = off.
        try Self.set(settings, "hiDPI", NSNumber(value: hiDPI ? 1 : 0))
        // Build one mode object per resolution in the spec.
        var modeObjs: [AnyObject] = []
        // Each mode needs width, height and refresh rate.
        for m in spec.modes {
            // If a mode cannot be created, fail.
            guard let o = Self.makeMode(modeCls, m.width, m.height, m.refresh) else {
                throw VirtualDisplayError.creationFailed("mode init failed \(m.width)x\(m.height)")
            }
            // Collect it.
            modeObjs.append(o)
        }
        // Give the settings the list of modes.
        try Self.set(settings, "modes", modeObjs as NSArray)

        // Step 4: apply the settings to the display (a method looked up by name).
        let sel = NSSelectorFromString("applySettings:")
        // Make sure the method exists on this macOS.
        guard display.responds(to: sel) else { throw VirtualDisplayError.apiUnavailable("applySettings: missing") }
        // Apply; false means macOS refused the settings.
        guard Self.applySettings(display, sel, settings) else { throw VirtualDisplayError.settingsRejected }

        // Step 5: read the new display's number; 0 would mean it was not created.
        guard let idNum = display.value(forKey: "displayID") as? NSNumber, idNum.uint32Value != 0 else {
            throw VirtualDisplayError.creationFailed("no displayID returned")
        }
        // Wrap everything in a handle. Keeping `display` inside it keeps the display alive.
        let h = VirtualDisplayHandle(displayID: idNum.uint32Value, spec: spec, name: name, object: display)
        // Remember it so a second create() returns the same display.
        handle = h
        // Done.
        return h
    }

    // Releasing our reference makes the display vanish.
    /// Releases the display; it disappears from the system immediately.
    public func destroy() {
        // Thread-safe.
        lock.lock(); defer { lock.unlock() }
        // Drop the handle (the object is freed once nothing else holds it).
        handle = nil
    }

    // These helpers call Objective-C methods by name. 'unsafeBitCast' reinterprets a raw function pointer as a Swift function type;
    // it is 'unsafe' because the compiler cannot check the signature, so each typealias below must exactly match the real method.
    // MARK: runtime helpers

    // Sets one property by name, after checking the object actually has a matching setter (e.g. setName:).
    private static func set(_ obj: NSObject, _ key: String, _ value: Any) throws {
        // Build the setter name: 'set' + capitalised key + ':'.
        let sel = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
        // Missing setter means the private API changed: throw instead of crashing.
        guard obj.responds(to: sel) else { throw VirtualDisplayError.apiUnavailable("property \(key) missing") }
        // Key-value coding: assign the value to the named property.
        obj.setValue(value, forKey: key)
    }

    // Function shapes for the three private methods we call: display init, mode init, and applySettings.
    private typealias InitDisplay = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    // Takes width, height and refresh rate.
    private typealias InitMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
    // Returns true if the settings were accepted.
    private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    // Allocates and initialises a display object by calling initWithDescriptor: manually.
    private static func makeDisplay(_ cls: NSObject.Type, _ desc: NSObject) -> AnyObject? {
        // The init method's name.
        let sel = NSSelectorFromString("initWithDescriptor:")
        // alloc reserves memory for a new object.
        let raw = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        // Make sure the object and its init method exist; find the method's code address.
        guard let inst = raw, inst.responds(to: sel), let imp = class_getMethodImplementation(cls, sel) else { return nil }
        // Treat that address as a callable function of the right shape.
        let f = unsafeBitCast(imp, to: InitDisplay.self)
        // Call it; takeRetainedValue takes ownership of the returned object.
        return f(inst, sel, desc)?.takeRetainedValue()
    }

    // Same technique for a mode object (width, height, refresh rate).
    private static func makeMode(_ cls: AnyClass, _ w: Int, _ h: Int, _ r: Double) -> AnyObject? {
        // The init method's name.
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        // Allocate, check the method exists, find its address.
        guard let allocd = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              allocd.responds(to: sel), let imp = class_getMethodImplementation(cls, sel) else { return nil }
        // Callable function of the right shape.
        let f = unsafeBitCast(imp, to: InitMode.self)
        // Call it with the size and refresh rate.
        return f(allocd, sel, UInt32(w), UInt32(h), r)?.takeRetainedValue()
    }

    // Calls applySettings: on the display and returns whether macOS accepted it.
    private static func applySettings(_ display: AnyObject, _ sel: Selector, _ settings: AnyObject) -> Bool {
        // Find the method's address (false if missing).
        guard let imp = class_getMethodImplementation(object_getClass(display), sel) else { return false }
        // Call it as a function and return its true/false answer.
        return unsafeBitCast(imp, to: Apply.self)(display, sel, settings)
    }
}
