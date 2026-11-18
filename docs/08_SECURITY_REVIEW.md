> Awaiting Jagex approval. Not for use. See the README.

# 08 Security review (adversarial, read-only)

Scope: docs/01, 03; LanternCore Noise, Framing, Pairing, Net; LanternHostKit; lantern-host main.swift; NetTransport.swift. Review was by reading code only; no serve/capture/inject was run. NOTE: Sources/LanternCore/Net changed during the review (PairM1 padding and anti-amplification were added); line numbers refer to the files as read after that change.

Tags: [verified-in-code] = read and traced; [suspected] = plausible, not fully traced.

## Findings

### M1 (medium) Stale input is replayed after a link stall; contradicts docs/03 rule 3 and T11 [verified-in-code]
ClientConnection.swift:133-137 sends every INPUT via `reliable()`. SecureSession.swift:69-75,119-129 retransmits for up to 30 x 100 ms and the receiver delivers buffered events in order once the gap fills. Scenario: the Wi-Fi stalls for 2 s while the user taps, the link returns, and the host injects those 2-second-old taps. The 50 ms per-class limiter drops most of a burst, but the first of each class still fires. Docs say input is "dropped if the link stalls, never replayed".
Fix: send INPUT unreliable (docs/01 sec. 5 already says so), or stamp events and drop any older than ~150 ms on the host.

### M2 (medium) Pairing can be locked out by any LAN device [verified-in-code]
HostServer.swift handlePairM1/handlePairM3 (about lines 323-352). Any source can send a well-formed PAIR_M1 (the host answers because pairing is open), then a junk PAIR_M3, and every failed M3 calls `policy.recordFailure()`. Five of these lock the code. The per-IP limit (20 per 10 s) does not help. Impact is DoS only; a guess is not credited. docs/01 sec. 2 says this is intended ("any source"), but a rogue device can also make a victim's pairing fail repeatedly.
Fix: count a failure only when the M3 comes from the same source that finished M1/M2 and the M3 failed within a short time, or allow one pending session per source, or show the user a lockout notice.

### M3 (medium) Key injection is not bound to the captured window, and mouse occlusion ignores overlay layers [verified-in-code]
InputInjector.swift:76-77 and 85, SystemWindowEnvironment.topWindow (line 117) only consider `layer == 0`.
(a) A click inside the target frame lands on any overlay above it (notification banner, floating panel, password-manager popup, system dialog). Those windows are at layer > 0 and are skipped by `topWindow`.
(b) `.key` only checks that the frontmost PID equals the target PID and that the cursor is in the target frame. Keystrokes go to the key window of that app. RuneLite or the Jagex Launcher can have another window (dialog, plugin config) as key window, so text can reach a window other than the captured one.
(c) The client can type 32 chars per event at about 20 events/s (640 chars/s) with ctrl/cmd/alt modifiers. `virtualKey: 0` with a unicode override limits system shortcuts, but app shortcuts on "a" (Cmd+A, Ctrl+A) are reachable. This is a keyboard channel the docs say is not offered (03 sec. 3: "no keyboard passthrough outside the game window").
Fix: compute topmost over all layers that have alpha and frame hit (`kCGWindowAlpha`>0); require the target to be the key window (AX `kAXFocusedWindow` window number); cap key rate and mods, or drop `.key` unless explicitly enabled by a host flag.

### L1 (low) ACK precedes the reorder-window check, so a message can be lost forever [verified-in-code]
SecureSession.swift:119-124. The receiver always ACKs, then drops anything `>= nextExpected + 256` ("sender will retry"), but the sender already deleted it on ACK. Because `unacked.count < 256` does not bound the sequence span (acked middle packets leave the table), one persistently lost low seq plus more than 256 later sends wedges the reliable channel: the missing seq never arrives and in-order delivery stops, while PINGs keep the session alive. A paired client can also do this deliberately.
Fix: ACK only after the seq is accepted into `buffered` or is a true duplicate (`ahead >= 0x8000_0000`).

### L2 (low) IK handshake replay has gaps [verified-in-code]
HostServer.swift:366-385. (1) `seenIK` is in RAM only, so after a host restart a captured IK_M1 stays valid for up to 60 s. (2) The timestamp is only a window check (not monotonic per peer as in WireGuard). (3) A captured M1 replayed from a spoofed source (the victim's address) starts a session, and the host begins streaming video to that address until the 10 s idle timeout. The data is AEAD-encrypted so there is no leak, but it is unauthenticated traffic redirection with no amplification limit (this only works if the original M1 was lost or blocked, because `seenIK` rejects it otherwise). Replay of the same M1 by an attacker can also race and displace the legit client's session.
Fix: keep a per-peer high-water timestamp (persisted) and require strictly greater; start streaming only after the first authenticated DATA packet from the client.

### L3 (low) Unauthenticated CPU and state exhaustion [verified-in-code]
`handleIK` does two X25519 operations per datagram before `isPaired` (HostServer.swift:368-372). The rate limit is per source IP (`allowHandshake`, line 282), which a LAN attacker can bypass by spoofing many sources. `rate` and `conns` (cap 64, stalest non-session evicted, lines 249-256) allow evicting the legitimate pairing connection and filling `pending` (cap 16) so pairing is blocked. Impact: DoS only, and the active session is protected from eviction.
Fix: add a global handshake budget per second in addition to per-IP; do the allowlist check before the second DH (not possible with IK, so budget instead).

### L4 (low) Bind and source policy weaker than docs/03 [verified-in-code]
BindCheck.parse (NetSupport.swift) only rejects the wildcard. Any address is accepted (public, 127.0.0.1, VPN). T3 "refuse non-private sources" is not implemented; `HostServer.handle` never checks the source address. If the interface IP changes, the listener goes to `.failed` and `listenerDied` tears down everything (good) but there is no rebind or notice other than the state callback. No exposure to other interfaces occurs because the bind is to one IP.
Fix: warn or refuse for non-RFC1918/ULA/link-local bind addresses; filter source IPs to the same subnet.

### L5 (low) Peer-supplied name is printed unsanitised [suspected]
HostServer.swift:354 `String(decoding: payload.prefix(64), as: UTF8.self)` can include control characters or ANSI escapes, and `.prefix(64)` can cut a UTF-8 sequence (replacement chars). It is stored in the Keychain record. It is not printed by main.swift (see I1) but will be by any future UI or log.
Fix: strip control characters and non-printables before storing.

### L6 (low) Keys are not zeroized; macOS host uses the legacy keychain [verified-in-code]
`KeyStore.loadDevicePrivateKey` returns `Data` that is never wiped; `psk` `Data` and HKDF outputs also stay in heap copies (NoiseHandshake, NetCrypto.psk). The host uses `useDataProtectionKeychain: false` (main.swift serve); on macOS the legacy keychain does not honour `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so other same-user processes that the user approves in the prompt can read it. Docs/03 asset A4 assumes a stronger store.
Fix: use the data-protection keychain with a signed binary or document the limit.

### I1 (info) SAS is dead code in both UIs [verified-in-code]
`SAS.derive` runs, but `onPaired` is never set in lantern-host/main.swift, and the iOS client never displays `PairedInfo.sas`. Safety does not currently depend on it because host authentication to the client comes from key confirmation: the client only stores the host after a DATA packet that decrypts under psk-derived keys (ClientConnection.swift:228-234). Docs/01 sec. 2 says SAS is "default on in UI"; that is not true yet. Also the paired peer is persisted and the session established before any user confirmation (HostServer.swift:355-360), so a mismatched SAS could not block it.

### I2 (info) Rekey and 2^64 counters
docs/01 says rekey every 2^32 packets or 1 h; there is no rekey. Counter exhaustion is handled (`nonceExhausted`) but unreachable in practice.

### I3 (info) A compromised paired phone is an automation source
Nothing limits a paired client to 1 touch = 1 human action; it can script 20 clicks/s per class. This is inherent but should be in docs/03 as an accepted risk (rule 3 is enforced only by client behaviour).

## Offline guess oracle after M3
A rogue "host" (impersonating the real one) gets the client's PAIR_M3, whose payload is encrypted under a key that includes the psk. It can guess the 50-bit code offline, but: the client discards the attempt after 3 s without a valid confirm, the real host still holds the code for at most 120 s, and 2^50 ChaCha/HKDF trials in that window is not realistic. QR secrets are 128 bits. Fine, with the residual that the stated "infeasible" is a 120 s race, not a mathematical bound; a long-lived QR/offline archive is useless after expiry.

## Checked and found fine
- Noise vs spec: HKDF output ordering (temp key = HMAC(ck, ikm); outputs T1..Tn with counter byte appended), MixKey (2 outputs), MixKeyAndHash (3 outputs: ck, MixHash(o1), k=o2), split order (initiator send = c1), `e` token MixKey under psk patterns, psk token at the end of msg3 only, prologue mixed before pre-messages, IK responder pre-message, protocol-name padding/hash, nonce = 4 zero bytes + 64-bit little-endian (correct for ChaChaPoly), 2^64-1 reserved. No deviation found. Low-order X25519 inputs are rejected by CryptoKit throwing.
- Replay windows (NoiseReplayWindow and ReplayWindow): slot math, shift clear, `diff >= size` boundary, window only updated after AEAD success, reserved counter, first-packet large counter. No off-by-one found.
- Framing parsers: all reads bounds-checked; no force unwrap, `try!` or precondition reachable from the network (the only `try!` are constants: `ChaChaPoly.Nonce` from 12 bytes, QR payload with fixed sizes). Fragment counts capped (1024), pending frames capped (8), input floats clamped and NaN-safe, trailing bytes rejected.
- Pair M1 amplification: the new `PairM1Padding` makes M2 <= request size; REJECT is 4 bytes; M3 and IK cached replies are smaller than their requests.
- Pairing policy: single use, 120 s TTL, lockout state machine (serialized on one queue, no race), constant-time compare, code `description` redacted, QR fingerprint pinned by the client before M3 is sent (ClientConnection.swift:218).
- IK: unknown-peer handshakes are silent, allowlist is constant-time, timestamp skew enforced, one client at a time, revoke removes the Keychain item.
- Capture scope: the window is fixed by `--window-id` at launch; the client has no control message that selects a window. `SCContentFilter(desktopIndependentWindow:)` captures that window only. Auto-stop observers exist for sleep, lock, user switch.
- CaptureGuard: `createExclusive` uses O_EXCL|O_NOFOLLOW with mode 0600, so the lstat check followed by create is not exploitable for the final path component (parent directory symlinks are still followed; use a private output directory).
- Input geometry: normalized coordinates out of 0..1 dropped; point strictly inside frame; frame re-fetched per event; mouse-up on drag end always attempted via `releaseAll`.
- Keychain on iOS: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable; release builds never fall back to the in-memory store (NetTransport.swift:24-29). Info.plist local-network keys were not in scope of the files read.

## Not reviewed
Info.plist and entitlements, H264Encoder, the iOS UI beyond NetTransport, `swift build`/`swift test` were not run.


## Fix status (2026-11-17)
- M1 fixed: INPUT carries a monotonic `sent_ms`; sent unreliable (dragEnd reliable); host drops events >250 ms older than the recent fastest offset; late dragEnd still releases. Tests: SecurityFixTests (freshness, wrap, gate, e2e stall).
- M2 fixed with trade-off (docs/01 sec. 11): junk M3 consumes nothing; counted failures need an authenticated static key; per-source budget 3 (< lock 5), pending caps, global handshake rate. A properly-formed wrong-psk M3 cannot be told apart from a typo, so a multi-address attacker can still lock the code. Existing five-failure test now lifts the per-source budget.
- M3 fixed: target must be AXFocusedWindow (matched by frame+title, refuses if AX unavailable), occlusion over all layers (alpha>0, below cursor level), key text <= 32 B and no control chars, modifiers stripped unless `--allow-modifiers`, global cap 40/s plus per-class 50 ms.
- L4 fixed for bind (private addresses only; source filtering still not done). L5 fixed (peer name sanitised).
- Open: L1, L2, L3 (partly: global handshake budget added), L6 (zeroization, legacy keychain), I1 (SAS unused), I2 (rekey), I3 (documented risk). AX match cannot separate two same-title, same-size stacked windows. Stale check cannot detect a delay on the very first event.
