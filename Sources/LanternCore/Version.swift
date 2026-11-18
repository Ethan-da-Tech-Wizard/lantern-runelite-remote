// ==============================================================================
// Program: Version.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Declares semantic versioning and protocol wire version constants for LanternCore.
//          Inputs: Compile-time version constants and protocol compatibility bounds.
//          Outputs: Static semantic version string and integer protocol version numbers.
//          Design Rationale: Guarantees client and host compatibility prior to handshake negotiation.
// ==============================================================================
// Version.swift
// Holds the one build/version label for the Lantern core library; shown in UI and logs by callers.

/// Namespace for the version string (an enum with no cases cannot be instantiated).
public enum LanternVersion { public static let string = "0.0.1-m0" }
