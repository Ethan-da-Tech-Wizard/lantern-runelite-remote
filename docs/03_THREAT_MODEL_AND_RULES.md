> Awaiting Jagex approval. Not for use. See the README.

# 03 Threat model and rules: LAN screen + touch streamer (Mac host, iPhone client)

Date: 2026-11-17. Not legal advice. [relayed] = taken from the research files in section 6, not re-verified.

## 1. Assets

| ID | Asset | Why it matters |
|---|---|---|
| A1 | Jagex session on the host (logged-in RuneLite, Launcher state) | Account takeover or ban risk. The app never holds it, but it lives on the same Mac. |
| A2 | Screen contents | Other windows, notifications and password managers must never stream. |
| A3 | Input control of the Mac | Injected clicks are real clicks on a real machine. |
| A4 | Pairing keys (host and phone) | Whoever holds one can connect without a code. |
| A5 | Account standing | A rule slip can ban it. |

## 2. Actors

| Actor | Capability |
|---|---|
| Passive sniffer on home Wi-Fi | Sees all LAN traffic. |
| Rogue LAN device | Scans, tries to pair, replays. |
| Malicious app on the Mac | Reads files, connects to our port, reads a weak key store. |
| Stolen or borrowed phone | Holds a valid client key. |
| Friend sharing | Pairs extra devices, lends phone or account. |
| Malicious Plugin Hub plugin | Runs Java inside RuneLite with the player's privileges. |

## 3. STRIDE with mitigations

| STRIDE | Threat | Mitigation (design feature) |
|---|---|---|
| Spoofing | Rogue device pairs or impersonates the host | Pairing code is one-use, expires in 2 minutes, 5 wrong tries lock out; Noise XXpsk3 (high-entropy code mixed into the handshake, never sent; see 01); mutual auth with pinned stored keys on every connection |
| Tampering | Injected or altered frames or input | Noise transport (ChaChaPoly AEAD, replay window) with pinned static keys; unauthenticated datagrams dropped; input decoded against a fixed schema and clamped |
| Repudiation | Who connected? | Planned: local log of pair, connect, revoke, lockout events. NOT IMPLEMENTED (stdout prints only) |
| Info disclosure | Sniffer reads video; other windows leak; keys leak | Encrypted transport; window-only capture (SCContentFilter on one window) so other windows and password managers never stream; keys in Keychain on both ends; no telemetry |
| Denial of service | Rogue device floods the port; sleeping Mac | Host off by default; bind to one given address (wildcard refused); refusing non-private sources is NOT IMPLEMENTED; connection and pairing rate limits; one client at a time |
| Elevation of privilege | Client gains wider Mac control | Input injection clamped to the captured window rectangle; no keyboard passthrough outside the game window; no file, shell or clipboard channel; kill switch |
| Stolen phone | Valid key in a thief's hands | Per-device revoke on host kills that key (no menu bar; revoke is via the key store); passcode/biometric gate on the client key is NOT IMPLEMENTED; idle timeout 10 s is implemented |
| Malicious Plugin Hub plugin | Plugin steals the Jagex session or exfiltrates | Not fully mitigable by this app. Policy: Quest Helper-type guidance plugins only, keep plugin count low, skip any that call external servers (RUNBOOK.md) [relayed]. Run RuneLite under a Mac user that holds nothing else sensitive |

Auto-stop (design): host stops on screen lock, sleep, lid close, user switch, idle timeout, or target window closing. Implemented: idle timeout only. Kill switch (design): menu-bar action and hotkey. Implemented: Ctrl-C / SIGTERM on `lantern-host serve` (and `HostServer.killSwitch()`); no menu bar, no hotkey.

### Mitigation status (audited against code 2026-11-17; see 09_DOC_AUDIT.md)
IMPLEMENTED+TESTED means a unit test exists on loopback or mocks, not that it was exercised on a real network or device.

| Mitigation | Status | Evidence |
|---|---|---|
| Off by default, no listener at start | IMPLEMENTED+TESTED | NetTests.testOffByDefaultAndWildcardRefused |
| Wildcard bind refused, single address | IMPLEMENTED+TESTED | BindCheck, same test |
| Refuse non-private sources | NOT IMPLEMENTED | no code |
| Code single-use, 120 s, 5-failure lock | IMPLEMENTED+TESTED | PairingTests (fake clock), NetTests wrong-code test; real-clock expiry untested |
| Pairing closed = silence | IMPLEMENTED+TESTED | testPairingClosedMeansSilence |
| Mutual auth; unknown/revoked peers get silence | IMPLEMENTED+TESTED | testRevokedPeerGetsSilence, testUnknownPeerRejectedSilently |
| Replay and tamper drop | IMPLEMENTED+TESTED | NetTests replay/tamper tests |
| Per-source handshake rate limit | IMPLEMENTED+TESTED | testHandshakeRateLimitPerSource |
| Kill switch (Ctrl-C/SIGTERM, killSwitch()) | IMPLEMENTED+TESTED (loopback; 1 s not timed) | testKillSwitch, testStopClosesListener |
| Idle timeout 10 s | IMPLEMENTED-UNTESTED | NetConfig.idleTimeout, HostServer tick |
| Input rate limit 50 ms, no queue | IMPLEMENTED+TESTED | testRateLimiterDropsNotQueues, HostKitTests |
| Clamp to window rect, drop out-of-range, frontmost/occluded refusal | IMPLEMENTED+TESTED (pure logic; real CGEvent never run) | HostKitTests |
| releaseAll on disconnect | IMPLEMENTED+TESTED (mock sink) | testReleaseAllAndGate |
| Window-only capture | IMPLEMENTED-UNTESTED | WindowCapturer.swift |
| Capture guard (confirm, 30 s cap, no overwrite, 0600) | IMPLEMENTED+TESTED | CaptureGuardTests |
| Keys in Keychain, ThisDeviceOnly, no sync | IMPLEMENTED-UNTESTED | KeychainKeyStore; test skipped (-34018); host CLI uses file keychain; client DEBUG may use in-memory store |
| No keys/codes/text in logs | IMPLEMENTED+TESTED (partial) | peerTag and redaction tests |
| No telemetry / third-party deps | IMPLEMENTED (script-checked, weak proof) | verify.sh, check_no_telemetry.sh |
| Auto-stop on lock/sleep/lid/user switch/window close | NOT IMPLEMENTED | no code |
| Hotkey kill, menu-bar revoke, biometric gate | NOT IMPLEMENTED | no code |
| Persistent event log | NOT IMPLEMENTED | stdout only |
| Rekey, key zeroization, FEC, second Noise implementation | NOT IMPLEMENTED | 00_INDEX |

## 4. What we will NOT do

1. Touch Jagex credentials, tokens or 2FA. The user types them into the official client themselves.
2. Modify, inject into, or hook the game client or RuneLite.
3. Automate, queue, buffer, repeat or script input. 1 touch = 1 input, sent immediately; dropped if the link stalls, never replayed.
4. Record, snapshot or store the stream or frames.
5. Send telemetry or link third-party SDKs.
6. Offer it publicly, for money, or as a hosted service.

## 5. Jagex-rules compliance checklist

All items [relayed] from the research files in section 6 (Jagex text via the OSRS wiki mirror or legal.jagex.com excerpts); no new claims here. Jagex has published nothing on remote play, so this is silence, not permission [relayed].

- [ ] 1 touch = 1 input. Rules bar software that "automatically moves the mouse pointer or generates mouse clicks or key presses" [relayed]. Our injection only transports a human's tap.
- [ ] No automation, macros, auto-clickers, AI agents [relayed].
- [ ] Official, unmodified RuneLite only, from the official source. RuneLite is on the approved client list; modified clients are "not permitted for any reason" [relayed].
- [ ] Own account only, one human per account. Sharing or lending an account is prohibited [relayed].
- [ ] Credentials stay with the player; the host never stores, types or relays them [relayed].
- [ ] Plugins: Plugin Hub only, guidance types such as Quest Helper; none on the Third Party Client Guidelines ban list (prayer or boss-attack cues, new server-sending menu entries, click-zone changes, unhiding interface) [relayed]. The list is non-exhaustive [relayed].
- [ ] Private, non-commercial, home residential IP [relayed, inferred in source].
- [ ] Optional: ask Jagex support in writing; keep the reply [relayed].

## 6. Sources

Background notes were kept in the author private working folder and are not part of this repository.

## 7. Privacy rules

- No analytics or crash reporters; no internet sockets.
- Logs: rule is local only, never uploaded. Currently stdout only; file logging and rotation are NOT IMPLEMENTED.
- Redaction: logs hold event type, time, device nickname and a short key fingerprint. Never pairing codes, keys, frames, coordinates, window titles or typed text.
- No frame is written to disk.

## 8. Before you share this with a friend

- [ ] Each friend uses their own Jagex account on their own login; never lend yours.
- [ ] Prefer their own Mac and phone. If they use yours, they get a separate macOS user and never see your session.
- [ ] Check the host shows only the RuneLite window in the preview.
- [ ] Device list holds only intended phones.
- [ ] Jagex 2FA is on for the account.
- [ ] Plugins: Quest Helper-type only; review the list together.
- [ ] Show them the kill switch.
- [ ] Home network only; no port forwarding, no VPN or cloud relay.

## 9. Acceptance tests
There are 14 tests, T1-T14 (no T15). Status per test is in 09_DOC_AUDIT.md sec. 5; none has recorded raw output yet. T9 and A2 rely on window-only capture; display-level capture (06) would void that guarantee.

| ID | Test | Pass |
|---|---|---|
| T1 | Host off at launch: `lsof -nP -iTCP -iUDP` shows no listener | none |
| T2 | Host on: `lsof` shows listener only on the LAN IP, not `*` or 0.0.0.0 | LAN IP only |
| T3 | Connect from non-private or other-interface source | refused |
| T4 | Wrong code x5 locks pairing; correct code still refused until lockout ends | locked |
| T5 | Code expires after 2 minutes; reuse of a used code fails | fails |
| T6 | Sniff a session: no plaintext video, input or code | none |
| T7 | Stolen-phone revocation: revoke on host, phone's next connect is refused and live session drops | refused |
| T8 | Keys are in Keychain on both ends, none in plists, logs or files (`grep -r` over app data) | none |
| T9 | Capture excludes other windows: open a password manager and Messages over/beside the game; neither appears in the stream | absent |
| T10 | Taps outside the captured window rect inject nothing; moving the window keeps mapping correct | no effect |
| T11 | Rapid taps: events equal taps (no repeat, queue or replay after link drop) | 1:1 |
| T12 | Auto-stop on screen lock, sleep, idle, window close | listener gone |
| T13 | Kill switch closes listener and connections within 1 second | closed |
| T14 | Telemetry: `lsof -i` and a deny-all-outbound firewall rule for the app show no internet sockets and no function loss | none |

Record raw command output for each test.
