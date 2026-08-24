# Proposed Gate 3: fixed XCTestManager proxy-channel open/close

Status: **PASS on Wi-Fi and physically cableless warm Wi-Fi→Cellular**.

Gate 2 proved three fixed TCP/DTX capability handshakes. It deliberately used only each connection's root DTX channel. The next smallest capability increase is to request the two fixed XCTestManager service channels and immediately close them, without sending an XCTest session message.

## Proposed single action

Starting from an existing, unexpired held RSD adapter:

1. Open and capability-handshake exactly two `com.apple.dt.testmanagerd.remote` transports.
2. On each transport, send exactly one root-channel `_requestChannelWithCode:identifier:` request for the compile-time identifier:

   ```text
   dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface
   ```

3. Require an empty successful channel-open reply under a fixed timeout.
4. Open no channel on dtservicehub and no third testmanagerd proxy channel.
5. Drop both proxy-channel handles and both transports before returning.
6. Return only a sanitized stage and a two-bit completion mask.

## Explicitly excluded

- `_IDE_initiateControlSessionWithCapabilities:`;
- `_IDE_initiateSessionWithIdentifier:capabilities:`;
- `_IDE_authorizeTestSessionWithProcessID:`;
- any session UUID or `XCTestConfiguration`;
- installation-proxy queries or arbitrary bundle identifiers;
- process control or runner launch;
- incoming XCTest driver channel registration;
- start-test-plan messages;
- WDA, screenshots, HID, UI input, passcode, or secrets;
- generic service/channel/selector/payload parameters;
- background execution or production Agent changes.

## Fail-closed controls

- A separate feature and fixed FFI function; no reuse of the broad upstream `xctest` feature.
- Compile-time service and proxy-channel strings only.
- Existing ten-minute held-session age gate and one-operation lock.
- Eight-second bound for each connect, handshake, and channel-open stage.
- Stage-specific sanitized errors; no raw peer data or identifiers returned.
- Binary positive assertions for the one proxy identifier.
- Binary negative assertions for session-init, authorization, process-launch, runner, WDA, and HID symbols.
- Static tests must prove that the fixed module contains no call to any session-init, authorization, launch, or test-plan method.
- First device run on Wi-Fi only; a warm cableless Cellular repeat only after the Wi-Fi result and source/binary evidence pass.

## Why this is a separate gate

A DTX proxy-channel request is a real protocol capability increase beyond Gate 2's root capability handshake. However, it still stops before XCTest session initialization, authorization prompts, runner launch, or UI control. Those remain separately gated.

Authorization received verbatim:

> **Tiếp tục Gate 3**

This authorization covered only the fixed proxy-channel open/close action above. It did not authorize XCTest session initialization, authorization, runner launch, WDA, HID, or UI control.

Evidence: `demo/2026-08-24_gate3-fixed-xctestmanager-proxy-pass.txt`.
