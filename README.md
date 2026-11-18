# Lantern: see and play your own RuneLite window on your iPhone

> ## ⚠️ Status: awaiting Jagex's reply. Please do NOT download, build or use this yet.
> This project is shared only so Jagex can read exactly what it does. It has not been approved. Until Jagex
> replies, treat this as read-only. Do not run it, and do not use it with any game account.

## What it is
Lantern shows one window of your own Mac (a RuneLite window) on your own iPhone over your home Wi-Fi.
Touches on the phone are turned into ordinary mouse and keyboard input on the Mac. There is no gameplay
automation: every in-game action comes from a live human touch or keystroke, and nothing repeats on its own.
The phone view is a picture of the window, so it can show whatever the window shows (including a login screen).
It does not read the game's memory, intercept its network traffic or modify RuneLite or the game client, and it has
no accounts, analytics or tracking. The iPhone app contains developer test hooks (launch arguments that pair and
send one test tap); they sit inside `#if DEBUG` blocks and are compiled out of release builds.

## How it is built
- `Sources/LanternCore`: the encrypted network protocol (Noise over UDP), pairing codes, input rules.
- `Sources/LanternHostKit` and `Sources/lantern-host`: the Mac side (window capture, video encoding, input).
- `Apps/LanternClient`: the iPhone app (SwiftUI): shows the video and turns touches into input events.
- `Tests`: automated tests. `docs`: protocol, architecture and threat model.

## Safety rules the Mac side enforces
It acts only on the one window it was started on, only while that window is in front and uncovered, rate-limits
input, and only talks to a phone that paired with a one-time code. Everything is commented line by line.

## Placeholders
The Apple team ID and app ID are placeholders everywhere they appear (`YOUR_TEAM_ID`, `com.example.lantern.client`).

## Not affiliated, no license
Lantern is an unofficial, independent project. It is not affiliated with, endorsed by or approved by Jagex Ltd. or
RuneLite. There is no license: all rights reserved until Jagex replies (see NOTICE.md).

## Reading the docs
Confidence tags in the docs: [V] verified from a source, [I] inferred, [U] unknown, [relayed] reported by someone else.
