# Jarvis on-device RSD probe (experimental Gate 1)

This target tests one proposition only:

> With LocalDevVPN already active and a pre-provisioned iOS 26 RPPairing record, can a foreground app pair-verify `10.7.0.1:49152`, establish the userspace tunnel, and complete an RSD handshake?

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
- No DVT, XCTest, WDA, HID, process launch, screenshots, or passcode access.
- Pairing data is bounded to 256 KiB, validated locally, and stored as `AfterFirstUnlockThisDeviceOnly` in a non-synchronizing Keychain item.
- USB bootstrap can stage only `Documents/bootstrap.mobiledevicepairing`; the app tightens its protection, validates it, moves it to Keychain, overwrites/removes the staged file, and rolls back Keychain if cleanup fails.
- Raw pairing identifiers, keys, service ports, UUIDs, and error text are never returned or logged.
- One foreground probe runs at a time with eight-second stage bounds.

## Source pin

`jkcoxson/idevice` is fetched at commit:

```text
63a341d7f624b5c1f2540e4cecb269151a2caf52
```

The local patch removes a private-key debug trace and bounds a CDTunnel response slice. See `DEPENDENCIES.lock`.

## Offline checks

```bash
python3 tests/test_static_policy.py
scripts/prepare_vendor.sh
(cd rust && cargo test --locked)
```

The unsigned iOS build runs on a macOS/Xcode 26 worker via `build-ios-rsd-probe.yml`.

## Device gate (not yet executed)

1. User installs and starts the App Store LocalDevVPN.
2. A pairing record is provisioned locally during an approved bootstrap and pushed to the fixed Documents filename.
3. User taps **Import fixed USB-staged record** while unlocked; the temporary file is removed.
4. User explicitly taps **Run read-only RSD probe**.
5. Success means only an RSD transport handshake. Missing developer services may indicate absent DDI and is not a transport failure.

No secret-bearing or UI-control action is permitted in this target.
