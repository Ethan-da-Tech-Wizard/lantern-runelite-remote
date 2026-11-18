// Program: Lantern - HostInfo.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Exposes the Lantern version to the Mac-side code.
//
// HostInfo.swift - exposes the Lantern version string to the host side.
// Who calls it: lantern-host/main.swift (usage text and the startup message).
// Key idea: the real number lives in LanternCore (LanternVersion.string); this just forwards it.

import LanternCore
/// A tiny namespace (an enum with no cases cannot be created, it only holds static members).
/// `version` re-exports the shared version string so the host program can print it without importing more.
// Static means: read it as HostInfo.version, no instance needed.
public enum HostInfo { public static let version = LanternVersion.string }
