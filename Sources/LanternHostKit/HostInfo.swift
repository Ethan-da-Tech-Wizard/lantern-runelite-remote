// ==============================================================================
// Program: HostInfo.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Provides host system diagnostics, hardware capability checks, and version information.
//          Inputs: Operating system version queries and bundle information.
//          Outputs: Host environment status report.
//          Design Rationale: Centralizes host environment telemetry and version queries for consistency.
// ==============================================================================
// HostInfo.swift - exposes the Lantern version string to the host side.
// Who calls it: lantern-host/main.swift (usage text and the startup message).
// Key idea: the real number lives in LanternCore (LanternVersion.string); this just forwards it.

import LanternCore
/// A tiny namespace (an enum with no cases cannot be created, it only holds static members).
/// `version` re-exports the shared version string so the host program can print it without importing more.
// Static means: read it as HostInfo.version, no instance needed.
public enum HostInfo { public static let version = LanternVersion.string }
