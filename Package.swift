// swift-tools-version:6.0
// Program: Lantern - Package.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: SwiftPM manifest: declares the LanternCore and LanternHostKit libraries, the lantern-host program and the test targets.
//
// Package.swift - the SwiftPM manifest (the recipe that tells Swift what to build).
// Who reads it: the `swift build` / `swift test` tools, never our own code.
// Key ideas: three build units (LanternCore, LanternHostKit, lantern-host) plus two test targets,
// and no third-party dependencies (Apple frameworks only).

// The PackageDescription module gives us the types used to describe a Swift package.
import PackageDescription

// Plain-English tour of the manifest below:
// Lantern: native LAN-only screen+touch streamer. No third-party dependencies (Apple frameworks only).
// A Package value is the whole description of the project; SwiftPM reads it to know what to build.
let package = Package(
    // The package's display name.
    name: "Lantern",
    // Minimum OS versions: macOS 14 for the host (it uses ScreenCaptureKit), iOS 17 for the phone side.
    platforms: [.macOS(.v14), .iOS(.v17)],
    // Products are what other projects (or you at the command line) can use after the build.
    products: [
        // Shared library: protocol, crypto and message types used by both host and phone.
        .library(name: "LanternCore", targets: ["LanternCore"]),
        // Mac-only library: window capture, encoding, input injection.
        .library(name: "LanternHostKit", targets: ["LanternHostKit"]),
        // The command-line program you run on the Mac.
        .executable(name: "lantern-host", targets: ["lantern-host"]),
    ],
    // Targets are the individual build units (a folder of Swift files under Sources/ or Tests/).
    targets: [
        // Core has no dependencies of its own.
        .target(name: "LanternCore"),
        // HostKit builds on top of Core.
        .target(name: "LanternHostKit", dependencies: ["LanternCore"]),
        // The host program uses both libraries. main.swift in Sources/lantern-host is its entry point.
        .executableTarget(name: "lantern-host", dependencies: ["LanternHostKit", "LanternCore"]),
        // Unit tests for the Core library.
        .testTarget(name: "LanternCoreTests", dependencies: ["LanternCore"]),
        // Unit tests for the HostKit library (they also use Core types).
        .testTarget(name: "LanternHostKitTests", dependencies: ["LanternHostKit", "LanternCore"]),
    ]
)
