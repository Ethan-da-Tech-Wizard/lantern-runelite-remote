# 01 Crypto and Protocol (host window stream, macOS host to iOS client, LAN)

Tags: [V]=verified-source, [I]=inferred, [U]=unknown. Sources: Noise spec https://noiseprotocol.org/noise.html ; CryptoKit https://developer.apple.com/documentation/cryptokit ; Network.framework https://developer.apple.com/documentation/network ; TLS options https://developer.apple.com/documentation/security/sec_protocol_options ; Keychain https://developer.apple.com/documentation/security/keychain-services ; WireGuard https://www.wireguard.com/protocol/ ; CPace https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/ ; OPAQUE RFC 9807.

## 1. Decision: Noise (XXpsk3 to pair, IK for every later session), over UDP

Comparison:
1. Noise over CryptoKit. CryptoKit has Curve25519 key agreement, ChaChaPoly, SHA256, HMAC/HKDF [V, CryptoKit docs]. BLAKE2 is not in CryptoKit [I], so use SHA256 (Noise_..._ChaChaPoly_SHA256 is a legal name per spec sec. 8 [V]). Handshake is about 200 lines of Swift; no dependency. Risk: we own a crypto implementation [I]; mitigate with the official test vectors (cacophony/snow vector files) [U: confirm exact vector file for XXpsk3/IK with SHA256].
2. TLS 1.3 via Network.framework (PSK or pinned self-signed cert via verify block; QUIC available). Apple-audited and a strong runner-up [I]. Rejected: external-PSK TLS with a short code allows offline guessing [I]; pinning needs our own pairing channel anyway; QUIC forces TLS stack, adds congestion control that hurts live video [I]; no control of datagram replay or framing.
3. SSH-style: needs a lib or hand-rolled; no gain over Noise [I].
4. PAKE (CPace/OPAQUE): ideal for low-entropy codes, but needs hash-to-curve; CryptoKit exposes none, so we would hand-roll or import a library [I]. Rejected for v1; instead use a longer code (below).
5. WireGuard: Noise_IK + ChaChaPoly underneath [V, wireguard.com/protocol]; why-not is purely operational: needs a utun interface and network config/root (NetworkExtension), violating owner constraints. We reuse its design (IK, counter + replay window, 1-RTT) without the VPN.

Pick: **Noise_XXpsk3_25519_ChaChaPoly_SHA256 (pairing) then Noise_IK_25519_ChaChaPoly_SHA256 (sessions)**. XXpsk3 puts psk at end of message 3 [V, sec. 9.4]. XX hides the initiator static with forward secrecy [V, sec. 7.8].

## 2. Pairing code use (important flaw avoided)
A short code as psk in XXpsk3 is attackable offline by an active attacker who impersonates the host: msg3 is encrypted under a key that includes the psk, so they can test guesses offline [I]. A 6-digit code is therefore NOT enough.
- Code = 10 Crockford-base32 characters (50 bits), shown on host as XXXXX-XXXXX, or QR carrying 128 bits plus host static fingerprint. Rolled per pairing attempt from SecRandomCopyBytes.
- psk = HKDF-SHA256(salt = "twu-stream-pair-v1", ikm = code bytes), then 32 bytes. Breaking it in the 120 s window needs about 2^50 work: infeasible [I]. Expired code is useless for a later MITM.
- Expiry 120 s, single use. Host counts failed msg3 authentications; 5 failures (any source) invalidates the code and requires pressing "Pair new device" again. Guessing is online-only: each guess costs the attacker one live handshake [I].
- Optional SAS: both sides show 6 decimal digits (SAS.swift: HKDF-SHA256 over the handshake hash, info "twu-stream-pair-v1 sas"); user compares. Whether any UI surfaces it is not verified. Catches a MITM who somehow had the code. Default on in UI, skippable.
- Pairing mode is open only while the user has the pair dialog visible; otherwise host ignores XX packets.

## 3. Keys, storage, revocation
- Each end has a static X25519 key (CryptoKit Curve25519.KeyAgreement). Store in Keychain, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, no iCloud sync (kSecAttrSynchronizable false) [V, Keychain docs for attrs]; Secure Enclave cannot hold X25519 (SE supports P-256) [I].
- Host keeps paired list (name, static pub, date) in Keychain items (KeychainKeyStore). Note: the `lantern-host` CLI constructs it with `useDataProtectionKeychain: false` (file keychain), and the Keychain test is skipped on the unsigned runner, so the accessibility attributes are unverified in practice; phone keeps one item per host (host static pub, name).
- Revocation: delete the phone entry on host; IK msg1 then fails allowlist and gets no reply (silent drop). Stolen phone: user revokes on host; no server needed. Phone side: Face ID/passcode gating via kSecAccessControl biometryCurrentSet optional [I].
- Re-pair: simply run pairing again; a new static key replaces the old entry. Host key rotation = all phones re-pair.

## 4. Handshake messages (all multi-byte ints big-endian)
Every datagram starts with a 4-byte header: `magic 0x54 0x57 | ver u8 =1 | type u8`.

| type | name | body |
|---|---|---|
| 0x01 | PAIR_M1 (XXpsk3 -> e) | e[32], tag[16] (48 B; empty payload) |
| 0x02 | PAIR_M2 (<- e,ee,s,es) | e[32], enc_s[48], enc_payload[16+n] |
| 0x03 | PAIR_M3 (-> s,se,psk) | enc_s[48], enc_payload[16+n] (payload: device name, utf8, max 64) |
| 0x10 | IK_M1 (-> e,es,s,ss) | e[32], enc_s[48], enc_ts[16+8] (unix ms u64) |
| 0x11 | IK_M2 (<- e,ee,se) | e[32], enc_payload[16] (empty) |
| 0x20 | DATA | see sec. 5 |
| 0x30 | REJECT | none, sent only for rate-limited pairing, never for IK (avoid oracle) |

PAIR_M1 is 48 bytes, not 32: in XXpsk3 the `e` token also does MixKey(e) [V, Noise spec psk modifier], so a cipher key is set and EncryptAndHash of the empty payload appends a 16-byte tag. Measured from NoiseHandshake (FramingTests.testPairM1MatchesRealNoiseOutput). Wire datagram = 4 + 48 = 52 B.

Prologue = "twu-stream-v1" || ver. Handshake datagram retransmitted by the initiator at 200 ms backoff; responder caches last reply for duplicates. After IK_M2, Split gives send/recv CipherStates (k1,k2) [V, sec. 5].

## 5. Transport framing
DATA datagram: `hdr(4) | session_id u32 | counter u64 | ciphertext | tag[16]`. AEAD nonce = Noise ChaChaPoly nonce from counter (32 zero bits + LE counter) [V, sec. 12.3]; counter explicit because UDP reorders (SetNonce, sec. 11.4 [V]). Header bytes and session_id are AAD. Counter 2^64-1 reserved [V]. Rekey (Noise Rekey) every 2^32 packets or 1 h is planned and NOT BUILT. Pair payload bounds are 16..80 B; DATA datagram max 1200 B.
Replay: 2048-packet sliding bitmap window per direction; drop counter below window or already seen; update only after successful decrypt [V sec. 11.4 requires tracking successful n].
Plaintext inside: `chan u8 | flags u8 | seq u32 | payload`.

| chan | content | delivery |
|---|---|---|
| 0 VIDEO | frame_id u32, frag_idx u16, frag_cnt u16, pts u64 us, flags(keyframe) u8, then Annex-B H.264 bytes (SPS/PPS inline on keyframes) | unreliable; one frame per fragments, max datagram 1200 B |
| 1 INPUT | `sent_ms u32` (sender monotonic clock, ms, wraps) then `type u8 | x u16 | y u16 | buttons u8 | keycode u16 (reserved, 0) | mods u8`, plus `keylen u8 | utf8` for key only. Types: 1 tap, 2 longPress, 3 dragStart, 4 dragMove, 5 dragEnd, 6 scroll, 7 zoom, 8 key. x,y u16 normalized 0..1 to window (scroll/zoom: -1..1 mapped to 0..65535). Key = UTF-8 text, 1..32 bytes, not a keycode. Mods bits (host InputInjector): 1 shift, 2 ctrl, 4 alt, 8 cmd | UNRELIABLE (no retransmit, never replayed); only dragEnd is RELIABLE (releases a held button). Host drops any event whose offset (host_now - sent_ms) exceeds the recent minimum offset (rotating 30 s window) by more than 250 ms; a late dragEnd is still applied. Mods are stripped by the host unless `--allow-modifiers`; global cap 40 events/s |
| 2 CONTROL | msg u8: 1 ACK seq u32, 2 NACK frame_id u32, 3 REQUEST_IDR, 4 WINDOW_INFO w,h u16, 5 BITRATE u32, 6 PING, 7 BYE | reliable (seq + ACK + 100 ms retransmit) except ACK, PING, BYE, which are sent unreliable |

Loss: client sends NACK/REQUEST_IDR on missed frame; no FEC in v1 [I].

## 6. Transport choice
UDP via NWConnection with NWProtocolUDP: lowest latency, no head-of-line blocking, one socket, no root/system config [I]. TCP adds retransmit stalls on Wi-Fi loss [I]. QUIC (NWProtocolQUIC) gives datagrams but mandates TLS 1.3 so a second crypto layer [I]. iOS needs the Local Network permission prompt. Bonjour discovery (NWBrowser) is planned and NOT BUILT; the client uses a host address. Does Network.framework UDP reliably keep ECN/Wi-Fi QoS marking: [U].

## 7. State machine
Host: IDLE -> (user opens pair dialog) PAIRING_OPEN[code, expiry] -> M1 -> M3 verified -> PAIRED(store key) -> IDLE. Failure: count++, count==5 or timeout -> IDLE. Session: LISTEN -> IK_M1 valid ts (|now-ts|<=60 s, not seen) and key in allowlist -> ESTABLISHED -> (BYE | 10 s silence) -> LISTEN. One active session at a time.
Client: UNPAIRED -> enter code/scan -> XX -> PAIRED; PAIRED -> IK -> ESTABLISHED; on 3 s no reply retry, then show "host not found".

## 8. LAN metadata leaks
Visible: IPs, MACs, UDP port, packet sizes/timing (reveals video activity, keyframes, input bursts), Bonjour (not built), message type bytes. Hidden: all content, static keys post-pairing (IK msg1 encrypts initiator static [V sec 7.8 style]). Pairing msg2 reveals host static to anyone who starts XX (probeable) [V, sec 7.8]: acceptable, pub key only.

## 9. Threats
| Threat | Defended? |
|---|---|
| Passive LAN sniffer | Yes: AEAD, forward secrecy from ephemerals [V]; traffic analysis not |
| Active MITM during pairing | Yes with 50-bit code + 120 s + SAS; a 6-digit code would NOT [I] |
| Active MITM later | Yes: IK authenticates both statics [V] |
| Rogue device on Wi-Fi | Yes: no reply without allowlisted key; can only flood UDP (DoS not defended) |
| Replay | Yes: counter window + IK timestamp/seen set; IK_M1 replay yields nothing [I] |
| Host spoofing | Yes after pairing (phone pins host static) |
| Stolen phone | Partly: revoke on host; device-locked Keychain; if phone unlocked, attacker connects until revoked |
| Compromised host Mac/malware | No |
| Screen content on host itself, DoS, traffic analysis | No |

## 10. Test vectors plan
1. Port official Noise test vectors for Noise_XXpsk3_25519_ChaChaPoly_SHA256 and IK (snow/cacophony JSON) and assert byte-equal handshake hash and ciphertexts [U: vector availability].
2. Unit: HKDF/psk derivation fixed vectors; replay window (reorder, dup, wrap edge); counter reserved value.
3. Interop: Swift host vs second implementation (e.g. python `noiseprotocol`) offline in a throwaway venv.
4. Negative: wrong code, expired code, 5-failure lockout, revoked key, stale timestamp, tampered tag, truncated datagram, fuzz of parser.
5. Real network: loss/reorder via local pf/dummynet shaping, packet capture to confirm no plaintext.


## 11. Pairing lockout accounting and bind policy (security fixes M2, L4, L5)
Only a PAIR_M3 whose encrypted static key authenticates (the sender ran the handshake against our ephemeral, so it received PAIR_M2 at its real address) and whose psk-bound payload then fails counts toward the 5-failure lock. Junk, truncated or replayed M3 consume nothing. One source IP may spend at most 3 counted failures per code (then it is ignored), so at least two sources are needed to lock a code; 2 pending handshakes per source, 16 pending overall, 20 handshakes/10 s per source and 100/s globally. Trade-off: a LAN attacker who runs the Noise handshake properly with a wrong psk can still spend counted failures; the per-source budget makes a lockout need several real addresses, and a user's own 4th typo from the same address is ignored. Offline-guess argument unchanged: PAIR_M2 carries no psk-dependent value and a wrong-code M3 gets no reply, so a guess is only testable by the host (<= 5 per code) or by a rogue host inside the 120 s window. The host binds only to RFC1918, 127/8, 169.254/16, ::1, fe80::/10, fc00::/7 addresses. Peer names are stripped of control, format, separator and private-use characters before storage.
