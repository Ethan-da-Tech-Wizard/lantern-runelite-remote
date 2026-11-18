> Awaiting Jagex approval. Not for use. See the README.

# 11 Guardrails: what Lantern does and does not do
Status: awaiting Jagex's reply. Not for use yet. This page lists, as plainly as possible, the limits built into the program so a reviewer can check each one in the code.

## What it is
A remote view of one window of your own Mac (an approved client, started by you through the Jagex Launcher, unmodified) on your own iPhone, with your touches replayed on the Mac as ordinary mouse and keyboard events.

## What it does not do
- No automation: no macros, no key sequences, no auto-click, no repeat, no hold-to-spam, no scripted or API input. One touch becomes one event (InputPlan.swift, InputGate.swift).
- It does not read game memory, pixels for game state, or the network traffic of the game, and it does not change RuneLite, the Jagex Launcher or the game files.
- It does not handle Jagex login details. The phone shows a picture of the window, so it can show whatever the window shows, including a login screen.
- Others cannot control anything: only a phone you paired yourself with a one-time code can send input, and the host serves one live session at a time. Friends who watch your phone only see pictures.
- It only acts inside the one window it was started on, only while that window is in front and uncovered (InputInjector.swift).
- It has no accounts, analytics or tracking (scripts/check_no_telemetry.sh).

## Timing, stated honestly
The host adds small fixed pauses so Java apps register the pointer: 20 ms before a mouse press, 30 ms before a release, 10 ms after each key press and each key release when typing. Input older than 250 ms is dropped, never replayed late, and at most 40 events per second are accepted. There is no smoothing, batching, recording or replay of input.

## Developer test hooks
The iPhone app has launch-argument test helpers (auto-pair, one test tap). They sit inside `#if DEBUG` blocks and are compiled out of release builds (ClientModel.swift).

## Questions we ask Jagex
Is this acceptable, and what limits would you want? If any part is a problem, which part?
