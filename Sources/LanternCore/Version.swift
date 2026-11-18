// Program: Lantern - Version.swift
// Programmer: Ethan-da-Tech-Wizard
// Last Modified: 2026-11-18
// Purpose: Holds the LanternCore version string and runtime build identifiers.
//
// Technical Design Rationale:
//   - Uninstantiable zero-case enum guarantees namespace isolation without runtime allocation.
//   - Provides immutable semantic version string for handshake negotiation and compatibility gating.

/// Namespace for the version string (an enum with no cases cannot be instantiated).
public enum LanternVersion {
    /// Semantic version identifier of the Lantern core protocol engine.
    public static let string = "0.0.1-m0"
}
