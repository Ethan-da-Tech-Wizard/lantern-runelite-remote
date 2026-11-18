// Views.swift
//
// PURPOSE: All the SwiftUI screens: the root ContentView, the PairView (enter host and code),
// the ConnectedView (live game video plus a hidden menu) and the SettingsView sheet.
//
// WHO CALLS IT: LanternClientApp shows ContentView; ContentView picks the other screens.
//
// KEY IDEAS:
//   - A SwiftUI `View` is a cheap description of what to draw. Its `body` is re-run whenever
//     data it reads (a @State value or a @Published property of the model) changes.
//   - `@State` = a small piece of private screen state; `@ObservedObject` = a model owned elsewhere
//     that this view watches; `@Binding`/`$name` = a two-way link to a value so a control can edit it.
//   - While streaming, the whole screen is the game video. Extra controls appear only when
//     the user taps with four fingers (menu) or three fingers (keyboard).

import SwiftUI

/// Root screen. It owns the one ClientModel and chooses between the pairing form and the stream.
struct ContentView: View {
    // `@StateObject`: SwiftUI creates the model once and keeps it alive as long as this view exists.
    @StateObject var model = ClientModel()
    /// Whether the Settings sheet is showing.
    @State private var showSettings = false
    /// The content of this screen.
    var body: some View {
        // NavigationStack gives a title bar and lets us attach a toolbar.
        NavigationStack {
            // Group lets us choose one of several screens with `switch`.
            Group {
                // Show a screen depending on the model's `screen` value.
                switch model.screen {
                // Not paired yet: the form.
                case .pair: PairView(model: model)
                // Paired: the live stream; its menu can open Settings through this closure.
                case .connected: ConnectedView(model: model, onSettings: { showSettings = true })
                }
            }
            // While streaming the screen is only the game: no bar, no gear. Four-finger tap opens the menu.
            // Gear button (pairing screen only) that opens Settings.
            .toolbar { if model.screen == .pair { ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            } } }
            // Hide the navigation bar while streaming so the game fills the screen.
            .toolbar(model.screen == .connected ? .hidden : .automatic, for: .navigationBar)
            // Hide the status bar (clock, battery) while streaming.
            .statusBarHidden(model.screen == .connected)
            // Hide the home indicator / system overlays while streaming.
            .persistentSystemOverlays(model.screen == .connected ? .hidden : .automatic)
            // Present SettingsView as a sheet when `showSettings` becomes true.
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            // A strip pinned to the top that shows the model's message, if there is one.
            .safeAreaInset(edge: .top) {
                // Only draw the strip when `banner` is not nil.
                if let b = model.banner {
                    // Red strip with white text.
                    Text(b).font(.footnote).padding(8).frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85)).foregroundStyle(.white)
                        // Tapping the strip dismisses it by clearing the message.
                        .onTapGesture { model.banner = nil }
                }
            }
        }
    }
}

/// The pairing form: the Mac's address, and the pairing code (or QR text).
struct PairView: View {
    // The shared model; typing into the host field edits `model.hostAddress` directly.
    @ObservedObject var model: ClientModel
    /// The code field text (local to this screen).
    @State private var text = ""
    /// True while pairing is in progress, to stop double taps.
    @State private var busy = false
    /// The form layout.
    var body: some View {
        // Form = the grouped list look used by iOS settings screens.
        Form {
            // Section 1: where the Mac is.
            Section("Host") {
                // `$model.hostAddress` is a binding: edits go straight into the model, which also saves them.
                TextField("Mac address (e.g. 192.168.1.20:7777)", text: $model.hostAddress)
                    // Keyboard hints: no auto-capital letters, no autocorrect, digits and punctuation first.
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
            }
            // Section 2: the one-time pairing code or pasted QR text.
            Section("Pairing code or QR text") {
                // `axis: .vertical` lets long QR text wrap onto several lines.
                TextField("10-character code, or paste LNT1... text", text: $text, axis: .vertical)
                    // Capital letters (codes are upper case), no autocorrect.
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().textContentType(.none)
                // Pair button; label changes while busy.
                Button(busy ? "Pairing..." : "Pair") {
                    // Copy the text first so we can clear the field right away.
                    let code = text
                    text = ""            // never keep or show the code after submit (single use)
                    busy = true
                    // Run the async pairing off the button action; when done, allow the button again.
                    Task { await model.pair(code); busy = false }
                // Disabled while busy or when nothing has been typed.
                }.disabled(busy || text.isEmpty)
            }
            // Section 3: a hint about demo mode.
            Section { Text("Real network mode (LAN only). To use the built-in synthetic stream instead, launch with -LanternDemo.")
                .font(.footnote).foregroundStyle(.secondary) }
        // Title shown in the navigation bar.
        }.navigationTitle("Pair")
    }
}

/// The streaming screen: full-screen video plus a menu that appears on a four-finger tap.
struct ConnectedView: View {
    // The shared model.
    @ObservedObject var model: ClientModel
    /// Called to open Settings (supplied by ContentView).
    var onSettings: () -> Void = {}
    /// Whether the on-screen keyboard is up.
    @State private var keyboardOn = false
    /// Whether the overlay menu is visible.
    @State private var menuOn = false
    /// Whether the 'really disconnect?' dialog is showing.
    @State private var confirmDisconnect = false
    /// The layout: video behind, optional menu at the bottom.
    var body: some View {
        // ZStack stacks views on top of each other; the menu sits at the bottom edge.
        ZStack(alignment: .bottom) {
            // Black backdrop so the letterbox bars are black even in the safe areas.
            Color.black.ignoresSafeArea()
            // The video view. The closures flip the menu / keyboard flags when the user taps with 4 / 3 fingers.
            StreamView(model: model, keyboardOn: $keyboardOn, onMenu: { menuOn.toggle() }, onKeyboard: { keyboardOn.toggle() }).ignoresSafeArea()
            // Only build the menu while it is switched on.
            if menuOn {
                // Menu contents in a column.
                VStack(spacing: 10) {
                    // One line of status: state, event count and the last event.
                    Text(statusText).font(.caption.monospaced()).foregroundStyle(.white)
                    // A row of three buttons.
                    HStack(spacing: 12) {
                        // Toggle the keyboard and close the menu.
                        Button { keyboardOn.toggle(); menuOn = false } label: { Label("Keyboard", systemImage: "keyboard") }
                        // Close the menu and open Settings.
                        Button { menuOn = false; onSettings() } label: { Label("Settings", systemImage: "gearshape") }
                        // Ask for confirmation before disconnecting.
                        Button(role: .destructive) { confirmDisconnect = true } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    // Gray bordered button style for all three.
                    }.buttonStyle(.borderedProminent).tint(.gray)
                    // Small text button to close the menu.
                    Button("Hide menu") { menuOn = false }.font(.footnote).foregroundStyle(.white.opacity(0.8))
                    // Reminder of the gestures.
                    Text("Four-finger tap: this menu  |  Three-finger tap: keyboard").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                // Dark translucent panel across the width.
                .padding(14).frame(maxWidth: .infinity).background(.black.opacity(0.78))
                // Fade in and out.
                .transition(.opacity)
            }
        }
        // Animate changes to `menuOn` over 0.15 seconds.
        .animation(.easeInOut(duration: 0.15), value: menuOn)
        // 'Are you sure?' dialog shown when `confirmDisconnect` is true.
        .confirmationDialog("Disconnect from the Mac?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            // Confirming closes the menu and disconnects (which returns to the pair screen).
            Button("Disconnect", role: .destructive) { menuOn = false; model.disconnect() }
            Button("Cancel", role: .cancel) {}
        }
        // When this screen appears, start connecting if nothing is happening yet.
        .task { if model.state == .idle { await model.connect() } }
        // Keep the phone from auto-locking while streaming.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        // Allow auto-lock again when leaving this screen.
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    /// Text for the menu's status line.
    var statusText: String {
        // Plain-English name of the state.
        let s: String
        // Turn the state into words.
        switch model.state {
        case .idle: s = "Disconnected"
        case .connecting: s = "Connecting"
        case .streaming: s = "Streaming"
        case .failed: s = "Error"
        }
        // Combine into one line.
        return "\(s) | events \(model.eventCount) | last: \(model.lastEvent)"
    }
}

/// Sheet with the host address, bitrate slider, and the button that forgets the pairing.
struct SettingsView: View {
    // The shared model.
    @ObservedObject var model: ClientModel
    // Lets the view close itself.
    @Environment(\.dismiss) private var dismiss
    /// The settings form layout.
    var body: some View {
        // Own NavigationStack so the sheet gets a title and a Done button.
        NavigationStack {
            Form {
                // Edit the saved Mac address.
                Section("Host address") {
                    TextField("192.168.1.20:7777", text: $model.hostAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                // The header shows the current bitrate in Mbps (kbps divided by 1000).
                Section("Bitrate hint: \(model.bitrateKbps / 1000) Mbps") {
                    // A slider needs a Double; this Binding converts to and from the model's Int and rounds to steps of 500 kbps.
                    Slider(value: Binding(get: { Double(model.bitrateKbps) }, set: { model.bitrateKbps = Int($0 / 500) * 500 }),
                           in: 1000...15000, step: 500)
                }
                // Destructive action: removes keys and address, then closes the sheet.
                Section {
                    Button("Forget host and keys", role: .destructive) { model.forgetHost(); dismiss() }
                }
            }
            // Title of the sheet.
            .navigationTitle("Settings")
            // Done button closes the sheet.
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
