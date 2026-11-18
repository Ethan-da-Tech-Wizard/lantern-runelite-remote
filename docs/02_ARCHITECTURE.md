> Awaiting Jagex approval. Not for use. See the README.

# Lantern: Architecture

Native Swift. macOS host (CLI only, `lantern-host`) plus an iOS client app. No web UI, no accounts, no telemetry, LAN only. Host is off until the user starts `serve`. Wire format and crypto are in 01; threats in 03; build status in 00_INDEX.md. This file was rewritten 2026-11-17 to match the code; an earlier draft described a TCP FrameCodec, SPAKE2 and a menu-bar app, none of which exist.

## 1. Repo layout (real)

```
Package.swift                 # LanternCore, LanternHostKit, lantern-host; no dependencies
Sources/
  LanternCore/                # protocol, crypto, framing, pairing, network (Foundation, CryptoKit, Network, Security)
    Version.swift
    Framing/    WireMessage, ChannelMessage, InputEvent, InputGate, ReplayWindow, VideoReassembly
    Noise/      NoiseHandshake, NoiseCipher
    Pairing/    PairingCode, PairingPolicy, SAS, KeyStore
    Net/        HostServer, ClientConnection, SecureSession, NetSupport
  LanternHostKit/             # macOS only
    WindowCapturer, WindowLister, WindowGeometry, H264Encoder, AnnexB,
    InputInjector, InputPlan, CaptureGuard, Session, SessionSource, HostInfo,
    VirtualDisplay, VirtualDisplayMath   # helper only, not wired into capture or serve (see 06)
  lantern-host/main.swift     # CLI
Apps/LanternClient/           # iOS app (Xcode project): Transport, NetTransport, DemoTransport, ClientModel,
                              # StreamView, H264Display, GestureMapper, Views, LanternClientApp; LanternClientTests/
Tests/LanternCoreTests/       # Framing, Net, Noise, Pairing, Version
Tests/LanternHostKitTests/    # CaptureGuard, HostInfo, HostKit, Session, VirtualDisplay
scripts/                      # bootstrap, verify, print_hashes, check_no_telemetry, build_ios_sim (.sh)
docs/                         # 00-07, 09, evidence/
SETUP.md
```

There is no macOS app target and no menu-bar UI. There is no SHARING.md or THREAT_MODEL.md; see SETUP.md and 03.

Rule: LanternCore imports Foundation, CryptoKit, Network, Security only.

## 2. Modules

| Module | Responsibility | Platform |
|---|---|---|
| LanternCore | wire framing, Noise handshakes, pairing code/policy/SAS, key store, UDP host server and client connection, reliable layer | macOS 14+, iOS 17+ |
| LanternHostKit | window capture (ScreenCaptureKit), H.264 encode (VideoToolbox), Annex B, CGEvent injection, capture guard, host session glue | macOS 14+ |
| lantern-host | CLI over HostKit | macOS |
| LanternClient | NetTransport/DemoTransport, decode and display, gestures, SwiftUI screens | iOS 17+ |

### LanternCore (key types; read the source for signatures)
- `FrameCodec` (Framing/WireMessage.swift): datagram codec. 4-byte header `magic 'T''W' | ver | type`; types PAIR_M1/M2/M3, IK_M1/M2, DATA, REJECT. Max datagram 1200 B (`maxDatagram`). Datagram-oriented, no stream reassembly.
- `ChannelMessage` / `ControlMessage` / `VideoFragment` (ChannelMessage.swift), `InputEvent` (InputEvent.swift), `ReplayWindow`, `VideoReassembly`, `InputGate` / `InputRateLimiter`. Details in 01 sec. 5.
- `NoiseHandshake`, `NoiseCipher`: Noise_XXpsk3 and Noise_IK over CryptoKit.
- `PairingCode`, `PairingPolicy` (120 s TTL, 5 failures, single use), `SAS` (6 decimal digits), `KeyStore` (`PairedPeerRecord`, `KeychainKeyStore`, in-memory store).
- `HostServer`: UDP listener (`start(bindAddress:port:)`, no wildcard, one client), `beginPairing()` / `beginPairingQR`, `sendVideoFrame`, `killSwitch()`, `stop()`.
- `ClientConnection`: `pair(code:)` / `pair(qr:)`, `connect(hostPublicKey:)`, `send(input:)`, `send(control:)`, `requestKeyframe()`.
- `SecureSession`: per-session sealing, replay window, reliable delivery (ACK, 100 ms retransmit, in-order, deduplicated), keepalive 2 s, idle timeout 10 s (NetConfig defaults).

### LanternHostKit
`WindowCapturer` (SCContentFilter on one window), `H264Encoder`, `InputInjector` (maps normalized coordinates to the captured window, `releaseAll()`), `InputPlan` (pure logic), `CaptureGuard`, `HostSession` (wires server, frame source, injector).

### CLI (`lantern-host`)
`list-windows`, `capture-test --window <substring> --out new-file.h264 [--seconds N<=30 | --long] --confirm-window <id>` (two-step: first run prints the matched window), `inject-test` (dry run unless `--really`), `serve --bind <LAN-IP> --port N --window-id <id> [--pair [--qr]]` (`--bind`, `--port`, `--window-id` required; no wildcard; Ctrl-C or SIGTERM is the kill switch). The CLI uses `KeychainKeyStore(useDataProtectionKeychain: false)` (file keychain); the data-protection path needs a signed app and its test is skipped on the unsigned runner.

## 3. Threading
Not a queue-per-stage design. Host and client network state live behind a serial queue inside HostServer / ClientConnection; SecureSession is a value type the owner serialises. Video is lossy (client sends NACK / REQUEST_IDR); input and control use the reliable layer. Per-thread details beyond this are not documented because they were not audited.

## 4. Video pipeline
Host: `SCContentFilter` on one window -> `SCStream` -> `VTCompressionSession` H.264 (no B-frames) -> Annex B with SPS/PPS on keyframes -> `VideoFragment`s -> `SecureSession` seal -> UDP. Client: `VideoReassembly` -> `H264Display` (decode and display). Capture runs only while a client is connected. Targets (glass-to-glass under 120 ms, 30 fps, 4 Mbps) are goals, not measured.

## 5. Input pipeline

| Touch | InputEvent | Host action |
|---|---|---|
| tap | `tap(x,y)` | left click at point |
| long press (0.5 s, guess) | `longPress(x,y)` | right click |
| drag | `dragStart/dragMove/dragEnd` | left down, move, up |
| two-finger pan | `scroll(dx,dy)` | scroll wheel |
| pinch | `zoom(delta)` | wheel |
| keyboard | `key(text:mods:)` | key text with modifiers |

Rules implemented: host rate limit 50 ms spacing, excess events dropped not queued (`InputRateLimiter`); coordinates clamped to 0...1 on decode; injector clamps to the captured window rect, refuses when the window is not frontmost or is occluded; `releaseAll()` on disconnect. Ordering and de-duplication come from the reliable layer's per-direction `seq` (in the channel header), not from a field on `InputEvent`; the injector does no separate seq check.

## 6. Security and pairing (summary of 01)
- Pairing: host prints a 10-character Crockford code (50 bits, 120 s, single use, 5 failures lock) or a QR (128 bits + host key fingerprint), only with `--pair`. Client runs Noise XXpsk3 with psk = HKDF-SHA256(code). The code is never sent; it is mixed into the handshake. No PAKE in v1. Optional SAS: 6 decimal digits derived from the handshake hash.
- Sessions: Noise IK with pinned static keys, ChaChaPoly, counter nonces, 2048-packet replay window. Unknown or revoked peers get no reply.
- Host binds one address given on the command line; wildcard is refused. One client at a time.
- Rekey is NOT implemented.

## 7. UI
Host: CLI only; state is printed to stdout with a `[lantern]` prefix. No menu-bar app, no revoke UI. Client: SwiftUI screens in Views.swift (Pair, Stream, Settings) on top of `ClientModel`; gesture, pair and settings screens have not all been driven on a device.

## 8. Logging and errors
Host logs are stdout prints only (no file, no os.Logger). Peers are shown as a 3-byte SHA-256 tag (`peerTag`); key text is redacted in descriptions. `scripts/check_no_telemetry.sh` greps sources and binaries for analytics SDK names (weak evidence, see 05).

## 9. Distribution
Source build only; see SETUP.md. Free Apple ID profiles expire every 7 days. No TestFlight.

## 10. Not built
- Bonjour discovery (NWBrowser); the client needs a host address.
- Menu-bar host app, hotkey kill switch, auto-stop on lock/sleep/window close, persistent event log, biometric gate (see 03).
- Audio. Virtual phone-shaped display capture (helper exists, not wired; see 06).
- Rekey, key zeroization, FEC, second Noise implementation, decoder-initiated IDR wiring (`StreamView.onNeedKeyframe` is a stub).

## 11. Milestones (status from 00_INDEX.md, 2026-11-17; for current counts run the scripts)

| M | Scope | Status |
|---|---|---|
| M0 | Package, scripts, targets compile | DONE |
| M1 | LanternCore: framing, Noise XXpsk3/IK, pairing | DONE |
| M2 | Host capture/encode/inject, CLI | PARTIAL (one accidental real capture; injection never run for real) |
| M3 | iOS client app | PARTIAL (simulator with synthetic stream; gestures not driven) |
| M4 | Encrypted UDP net layer and pairing e2e | PARTIAL (loopback only) |
| M5 | Touch to mouse | PARTIAL (headless wiring and mock tests; no real CGEvent run) |
| M6 | Real iPhone over Wi-Fi | TODO (not run on a phone) |
| M7 | Hardening, fuzzing, docs | TODO |

Verification is `swift test` (see `.build/bootstrap-logs` after `scripts/bootstrap.sh`, and docs/evidence/) and `scripts/verify.sh`. Earlier per-milestone commands (`lantern-host record`, `run_loopback.sh`, `verify.sh M4`, tcpdump check) do not exist.
