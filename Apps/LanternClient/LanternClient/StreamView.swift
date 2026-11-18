// ==============================================================================
// Program: StreamView.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: UIKit-to-SwiftUI bridge hosting the low-latency hardware video display layer and gesture recognizers.
//          Inputs: Decoded video frames from transport and raw touchscreen gesture recognizer events.
//          Outputs: Rendered full-screen video layer and normalized InputEvents emitted to view-model.
//          Design Rationale: Uses UIViewRepresentable to host AVSampleBufferDisplayLayer and UIKit UIGestureRecognizers
//          for sub-frame touch and render performance.
// ==============================================================================
// StreamView.swift
//
// PURPOSE: Bridges UIKit into SwiftUI. It builds the real UIView that shows the video and catches
// touches and keystrokes, and wraps it so SwiftUI screens can place it.
//
// WHO CALLS IT: ConnectedView (Views.swift) draws `StreamView`. The transport pushes video into
// `VideoView.sink`; the touch gestures are turned into events by GestureMapper and sent to the model.
//
// KEY IDEAS:
//   - Swift Views & UIKit Bridging: `UIViewRepresentable` lets SwiftUI host an underlying UIKit view.
//     SwiftUI calls `makeUIView` once to construct it and `updateUIView` whenever state mutates.
//   - Video Pipeline Comparison (WebRTC vs MJPEG vs H.264/Annex B):
//     * WebRTC Pipeline: Provides adaptive bitrate and jitter buffering, but brings massive dependency
//       overhead (libwebrtc), SDP/ICE signaling handshakes, and higher CPU/battery drain on mobile.
//     * MJPEG Pipeline: Simple HTTP multipart JPEG stream, but lacks inter-frame compression, demanding
//       10x-20x the bandwidth (15-30 Mbps) and incurring severe frame pacing jitter.
//     * Lantern's Hardware H.264 over Noise/UDP Pipeline: Streams raw Annex B NAL units directly into Apple's
//       hardware-accelerated `AVSampleBufferDisplayLayer`. Delivers sub-15ms glass-to-glass latency with
//       under 2 Mbps bandwidth, zero third-party dependencies, and minimal battery impact.
//   - Touch Controls & Gesture Mapping:
//     * Touch events are captured via UIKit UIGestureRecognizers attached to the video view.
//     * Touches become mouse events on the Mac: finger gesture -> GestureMapper -> InputEvent
//       (normalized 0.0...1.0 coordinates relative to video aspect rect) -> Noise/UDP -> Mac CoreGraphics injection.
//     * One-finger tap = left click; two-finger tap / long-press = right click; one-finger drag in 3D viewport =
//       camera rotation via middle mouse drag; two-finger drag = panning; pinch = scroll-wheel zoom.
//     * Three-finger tap toggles the virtual keyboard; four-finger tap toggles the client settings menu.

import SwiftUI
import UIKit
import AVFoundation
import LanternCore

/// Hosts the display layer, letterboxed, plus the gesture mapper and an invisible keyboard catcher.
// `final` = no subclasses. It is a plain UIView with a video layer inside.
final class VideoView: UIView {
    /// Decodes and displays the video. The layer inside it is added to this view's layer tree.
    let sink = DisplayLayerSink()
    /// Converts finger gestures into game input events.
    let mapper: GestureMapper
    /// Invisible view (it is given no frame) that receives typing from the on-screen keyboard.
    let keys = KeyCatcher()

    /// Called when the user taps with four fingers (open the menu).
    var onMenu: (() -> Void)?
    /// Called when the user taps with three fingers (toggle the keyboard).
    var onKeyboard: (() -> Void)?
    // `@objc` makes these callable by UIKit's target/action system (gesture recognizers call them by selector).
    @objc private func keyboardTapped() { onKeyboard?() }
    @objc private func menuTapped() { onMenu?() }

    /// Builds the view. `emit` is where every input event is delivered.
    init(emit: @escaping (InputEvent) -> Void) {
        // The mapper turns gestures into events and passes them to `emit`.
        mapper = GestureMapper(emit: emit)
        // Required UIKit step: finish initialising the superclass (the frame is set later by layout).
        super.init(frame: .zero)
        // Black behind the video so letterbox bars look right.
        backgroundColor = .black
        // Put the video display layer inside this view.
        layer.addSublayer(sink.layer)
        // Typed keys go through the same `emit` path.
        keys.emit = emit
        // The key catcher is invisible; it just has to be in the view tree to take focus.
        addSubview(keys)
        // Install tap / long-press / one-finger drag / pinch recognizers on this view (camera rotate is the one-finger drag on the game world).
        mapper.attach(to: self)
        // Four-finger tap -> menu.
        let four = UITapGestureRecognizer(target: self, action: #selector(menuTapped))
        // Require exactly four fingers at once so it cannot be mistaken for a single tap.
        four.numberOfTouchesRequired = 4
        // Attach it to the view so UIKit starts watching touches.
        addGestureRecognizer(four)
        // Three-finger tap -> keyboard.
        let three = UITapGestureRecognizer(target: self, action: #selector(keyboardTapped))
        three.numberOfTouchesRequired = 3
        addGestureRecognizer(three)
        // When the video's pixel size becomes known, tell the mapper so its letterbox math is right.
        sink.onSize = { [weak self] s in self?.mapper.videoSize = s }
    }
    // Needed because UIView supports loading from storyboards; we never do, so crash if it happens.
    required init?(coder: NSCoder) { fatalError() }
    // Called by UIKit whenever the size changes: keep the video layer exactly filling the view.
    override func layoutSubviews() { super.layoutSubviews(); sink.layer.frame = bounds }
}

/// One key event per typed character. Never logs or displays what was typed.
// (UIKeyInput is the protocol that makes a view able to receive typed text.)
final class KeyCatcher: UIView, UIKeyInput {
    /// Where typed keys are sent.
    var emit: ((InputEvent) -> Void)?
    /// Tells iOS there is text, so the delete key stays active.
    var hasText: Bool { true }
    /// Lets this view take keyboard focus (which shows the keyboard).
    override var canBecomeFirstResponder: Bool { true }
    /// Turn off autocorrect so the game receives exactly what was typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    /// Turn off auto-capitalisation.
    var autocapitalizationType: UITextAutocapitalizationType = .none
    /// Turn off spell checking.
    var spellCheckingType: UITextSpellCheckingType = .no
    /// Called by iOS for each typed string; sends one key event per character.
    func insertText(_ text: String) {
        // Loop over the characters one by one.
        for ch in text { emit?(.key(text: String(ch), mods: 0)) }
    }
    /// Backspace is sent as the control character 8.
    func deleteBackward() { emit?(.key(text: "\u{8}", mods: 0)) }
}

/// The SwiftUI wrapper around VideoView, placed by ConnectedView.
struct StreamView: UIViewRepresentable {
    /// The shared model (events go to it; its transport gets the video sink).
    @ObservedObject var model: ClientModel
    /// True when the keyboard should be showing; the view follows it.
    @Binding var keyboardOn: Bool
    /// Closure run on a four-finger tap.
    var onMenu: () -> Void = {}
    /// Closure run on a three-finger tap.
    var onKeyboard: () -> Void = {}

    /// SwiftUI calls this once to create the UIKit view.
    func makeUIView(context: Context) -> VideoView {
        // Every gesture/key event goes to `model.send`. `[weak model]` avoids a retain loop.
        let v = VideoView { [weak model] e in model?.send(e) }
        v.sink.onNeedKeyframe = { [weak model] in model?.transport.requestKeyframe() }   // delivered on main
        // Pass the closures along.
        v.onMenu = onMenu
        v.onKeyboard = onKeyboard
        // Give the transport the sink so incoming video frames reach this view's display layer.
        model.transport.videoSink = v.sink
        // Hand the finished view to SwiftUI.
        return v
    }
    /// SwiftUI calls this whenever state changes: refresh the closures and show/hide the keyboard.
    func updateUIView(_ v: VideoView, context: Context) {
        // The closures may have changed, so copy the latest ones.
        v.onMenu = onMenu
        v.onKeyboard = onKeyboard
        // Becoming first responder shows the keyboard; resigning hides it.
        if keyboardOn { v.keys.becomeFirstResponder() } else { v.keys.resignFirstResponder() }
    }
}
