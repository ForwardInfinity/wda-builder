# Jarvis on-device RSD probe (experimental Gate 0–2)

This target first tests whether a foreground app can pair-verify the fixed LocalDevVPN peer and complete RSD. Gate 2 then tests only three fixed DTX transport capability handshakes over an already-held adapter.

It is deliberately separate from production Agent v19.

## Compiled safety boundary

- Different bundle ID: `com.forwardinfinity.jarvisrsdprobe`.
- No Agent server URL or command channel.
- No background mode.
- No arbitrary host, port, service, payload, or relay API.
- Fixed destination `10.7.0.1:49152`.
- Pair-verify only. It never calls upstream `RemotePairingClient::connect` because that method falls back to pair-setup.
- No PIN callback or pair-setup entry point is exported.
- It checks only four compile-time service names and returns a bit mask/count.
- Gate 1 has no DTX operation. Gate 2 compiles only the DTX message/transport core needed for three fixed capability handshakes.
- Gate 2 does not compile process-control, screenshot, XCTest orchestration, installation proxy, runner launch, WDA, HID, or passcode access.
- Pairing data is bounded to 256 KiB, validated locally, and stored as `AfterFirstUnlockThisDeviceOnly` in a non-synchronizing Keychain item.
- USB bootstrap can stage only `Documents/bootstrap.mobiledevicepairing`; the app reads it only inside its data-protected sandbox, validates it, moves it to Keychain, overwrites/removes the staged file, and rolls back Keychain if cleanup fails.
- One fixed `NWConnection` may invoke the official Local Network permission flow; it uses the same endpoint and sends no application data. No Bonjour browser or listener is compiled.
- Raw pairing identifiers, keys, service ports, UUIDs, and error text are never returned or logged.
- One foreground operation runs at a time with eight-second network-stage bounds.
- The optional held-adapter gate retains only the userspace adapter and fixed RSD port, expires after ten minutes, and has an explicit stop. It is labeled warm continuity, not cold recoverability.
- Gate 2 opens one `com.apple.instruments.dtservicehub` and two `com.apple.dt.testmanagerd.remote` transports, performs fixed DTX capability handshakes, then drops all three before returning. It opens no DTX service channel and performs no session init or authorization.

## Source pin

`jkcoxson/idevice` is fetched at commit:

```text
63a341d7f624b5c1f2540e4cecb269151a2caf52
```

The local patch removes a private-key debug trace, bounds a CDTunnel response slice, separates pair setup from pair verify, and adds the fixed transport-only Gate 2 DTX module. See `DEPENDENCIES.lock`.

## Offline checks

```bash
python3 tests/test_static_policy.py
scripts/prepare_vendor.sh
(cd rust && cargo test --locked)
```

The unsigned iOS build runs on a macOS/Xcode 26 worker via `build-ios-rsd-probe.yml`.

## Gate 1 result — 2026-08-24

1. LocalDevVPN connected with `10.7.0.0/24` and fake peer `10.7.0.1`.
2. The USB-staged record was validated, stored in device-only Keychain, and removed from Documents.
3. Before Local Network authorization, BSD TCP failed with Darwin `EHOSTUNREACH` (`1/65`) without a prompt. The bounded fixed `NWConnection` triggered the official prompt; the user allowed it directly on-device.
4. Wi-Fi and physically cableless Wi-Fi both completed pair-verify, TLS-PSK/userspace tunnel setup, and RSD protocol 7 with 82 advertised services.
5. A fresh attempt with Wi-Fi disabled and Cellular active failed closed at the fixed TCP endpoint with `ECONNREFUSED` (`1/61`). Fresh Cellular recovery therefore did **not** pass.
6. A Wi-Fi-established held adapter remained usable after cable removal, Wi-Fi-to-Cellular transition, iPhone lock, and a VPS restart. The Agent reconnected over Cellular in 1.312 seconds; after direct user unlock, the same adapter again completed RSD protocol 7 with 82 services.
7. The held adapter was explicitly stopped and the UI confirmed `None`.

This proves warm on-device RSD continuity only. It does not prove direct testmanager channels, XCTest/WDA, UI control, secure unlock, cold app/VPN recovery, or reboot/DDI recovery. See `demo/2026-08-24_gate0-gate1-ondevice-rsd-probe-build.txt`.

## Gate 2 result — 2026-08-24

1. On Wi-Fi, one fixed dtservicehub transport and two fixed testmanagerd transports each completed the DTX published-capabilities handshake, then all three were closed: PASS.
2. The same operation passed again after physical cable removal and a warm Wi-Fi-to-Cellular transition. The immediately preceding held-RSD check was `Complete`.
3. Independent host checks during the second result showed zero Apple USB devices, zero libimobiledevice USB devices, and zero local RSD/WDA holders.
4. The held adapter was explicitly stopped after evidence collection.
5. No DTX service channel, XCTest initialization/authorization, process or runner launch, WDA, HID, UI action, or secret access occurred.

This is a **warm on-device DTX-transport continuity PASS**. It does not prove fresh Cellular pairing, cold recovery, an on-device XCTest controller, or UI control. See `demo/2026-08-24_gate2-fixed-dtx-transport-pass.txt`.

No secret-bearing or UI-control action is permitted in this target. Any increase to XCTest session initialization, authorization, or runner launch requires a separately authorized gate.
