// Program: Lantern - LanternClientApp.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: App entry point for the iPhone app.
//
// LanternClientApp.swift
//
// PURPOSE: The app's entry point. iOS starts here when the app launches.
// WHO CALLS IT: The operating system (because of the `@main` marker).
// KEY IDEAS: A SwiftUI `App` describes a Scene; a `WindowGroup` scene gives the app one window
// whose content is `ContentView` (defined in Views.swift).

import SwiftUI

// `@main` tells Swift: begin running the program from this type.
/// The app itself. It has no state of its own; it only says what the first screen is.
@main
struct LanternClientApp: App {
    // `body` lists the scenes. One window, filled with ContentView, which owns the ClientModel.
    var body: some Scene { WindowGroup { ContentView() } }
}
