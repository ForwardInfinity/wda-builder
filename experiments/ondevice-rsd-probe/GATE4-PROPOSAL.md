# Proposed Gate 4: fixed XCTest control-session initialization

Status: **not authorized and not implemented**.

Gate 3 proved that two fixed modern XCTestManager IDE-to-daemon proxy channels can be opened and closed. The next smallest capability increase is to initialize only the control-side XCTestManager session on one fixed control channel, then close it immediately.

## Proposed single action

Starting from an existing, unexpired held RSD adapter:

1. Open and capability-handshake exactly one `com.apple.dt.testmanagerd.remote` transport.
2. Request exactly one compile-time proxy channel:

   ```text
   dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface
   ```

3. Send exactly one fixed method on that channel:

   ```text
   _IDE_initiateControlSessionWithCapabilities:
   ```

4. Supply one locally generated, fixed NSKeyedArchive object representing an empty `XCTCapabilities` dictionary, matching the iOS 17+ pymobiledevice3/Xcode control-init form.
5. Require a bounded DTX reply that decodes as an `XCTCapabilities` wrapper; return no peer dictionary or raw payload.
6. Drop the channel and transport before returning a sanitized stage/status bit.

## Explicitly excluded

- a second/main testmanagerd channel;
- `_IDE_initiateSessionWithIdentifier:capabilities:`;
- session UUIDs or `XCTestConfiguration`;
- `_IDE_authorizeTestSessionWithProcessID:` or any PID;
- authorization-passcode entry;
- installation-proxy queries or bundle IDs;
- process control, runner launch, or XCTestDriverInterface;
- incoming driver registration or start-test-plan messages;
- WDA, screenshots, HID, UI input, passcode, or secrets;
- generic destination, service, channel, selector, payload, or capability input;
- background execution or production Agent changes.

## Fail-closed controls

- Separate fixed FFI function; no broad upstream `xctest` feature.
- One compile-time testmanager service, proxy identifier, selector, and empty-capabilities encoder.
- Existing held-session age gate and one-operation lock.
- Eight-second bounds for RSD, TCP, DTX handshake, channel open, and control-init reply.
- Reply validation returns only a one-bit success mask; no raw capabilities leave Rust.
- Any failure stops the held adapter and permits no automatic retry.
- Binary positive assertion for the one control-init selector.
- Binary negative assertions for main-session init, authorization, driver channel, process launch, runner, WDA, and HID.
- Static tests must show exactly one control-init call and no other `_IDE_` selector in the fixed Gate 4 module.
- First device run on Wi-Fi only; one warm cableless Cellular repeat only after Wi-Fi success and evidence checks.

## Unexpected prompt rule

Gate 4 is not authorization. It is not authorized to enter any authorization passcode. If an XCTest authorization prompt unexpectedly appears, the user must enter nothing, report the prompt, and let the bounded operation fail/close. Any later authorization interaction requires a separate gate and direct on-device user entry only after prompt evidence is confirmed.

## Why this is a separate gate

Unlike Gate 3's channel request, `_IDE_initiateControlSessionWithCapabilities:` changes XCTestManager protocol state. It therefore requires explicit consent even though it creates no main test session, launches no process, and performs no UI action.

Implementation and device testing require the explicit phrase:

> **Tiếp tục Gate 4**
