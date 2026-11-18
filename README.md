# Lantern: see and play your own RuneLite window on your iPhone

> ## ⚠️ Status: awaiting Jagex's reply. Please do NOT download, build or use this yet.
> This project is shared only so Jagex can read exactly what it does. It has not been approved. Until Jagex
> replies, treat this as read-only. Do not run it, and do not use it with any game account.

## What it is
Lantern shows one window of your own Mac (a RuneLite window) on your own iPhone over your home Wi-Fi.
Touches on the phone are turned into ordinary mouse and keyboard input on the Mac. Every action in the game is
a human tap or keystroke; nothing is automated, scripted or repeated. It does not read or change the game client,
never sees login details, and has no accounts, analytics or tracking.

## How it is built
- `Sources/LanternCore`: the encrypted network protocol (Noise over UDP), pairing codes, input rules.
- `Sources/LanternHostKit` and `Sources/lantern-host`: the Mac side (window capture, video encoding, input).
- `Apps/LanternClient`: the iPhone app (SwiftUI): shows the video and turns touches into input events.
- `Tests`: automated tests. `docs`: protocol, architecture and threat model.

## Safety rules the Mac side enforces
It acts only on the one window it was started on, only while that window is in front and uncovered, rate-limits
input, and only talks to a phone that paired with a one-time code. Everything is commented line by line.

## Placeholders
The Apple team ID and app ID in the Xcode project are placeholders (`YOUR_TEAM_ID`, `com.example.lantern.client`).
