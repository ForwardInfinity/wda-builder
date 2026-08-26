#!/usr/bin/env python3
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
V21 = ROOT / "agent/ios/JarvisAgentV21"
FULL = (V21 / "Sources/FullUIBridge.swift").read_text()
AGENT = (V21 / "Sources/AgentController.swift").read_text()
LOCAL = (V21 / "Sources/LocalControlBridge.swift").read_text()
UI = (V21 / "Sources/JarvisAgentApp.swift").read_text()
SERVER = (ROOT / "agent/jarvis_ui_server.py").read_text()
FIXED_SERVER = (ROOT / "agent/jarvis_agent_server.py").read_text()


class V21FullUIPolicy(unittest.TestCase):
    def test_fixed_secure_command_plane_is_unchanged(self):
        match = re.search(r"private let allowedCommands = Set\(\[(.*?)\]\)", AGENT, re.S)
        self.assertIsNotNone(match)
        commands = re.findall(r'"([a-z0-9-]+)"', match.group(1))
        self.assertEqual(commands, [
            "ping", "probe-local-control", "wda-home", "wda-launch-settings",
            "wda-continue-recovery", "wda-keyboard-probe", "secure-unlock",
        ])
        self.assertNotIn("jarvis-ui", FIXED_SERVER)
        self.assertIn('ios-standalone-21r1-full-ui', AGENT)

    def test_full_ui_requires_direct_opt_in_and_visible_execution(self):
        self.assertIn("Explicit opt-in for unlocked screens", UI)
        self.assertIn("fullUI.enableFromUserAction()", UI)
        self.assertIn("ContinuedRecoveryManager.shared.active", FULL)
        self.assertIn("FullUIBridge.shared.stopForRecoveryExpiration()", (V21 / "Sources/ContinuedRecoveryManager.swift").read_text())
        self.assertNotIn("UserDefaults.standard.set", FULL)

    def test_every_generic_request_is_lock_gated(self):
        execute = FULL.index("private func execute")
        lock = FULL.index("readLockState", execute)
        effect = FULL.index("performWDARequest", lock)
        self.assertLess(lock, effect)
        self.assertIn('error: "device-locked"', FULL)
        self.assertIn("guard !locked", FULL)
        self.assertNotIn("DevicePasscodeStore", FULL)
        self.assertNotIn("ControllerPairingRecordStore", FULL)

    def test_transport_and_bodies_are_bounded(self):
        self.assertIn("/jarvis-ui/v1/poll", FULL)
        self.assertIn("/jarvis-ui/v1/result", FULL)
        self.assertIn("maximumRequestBytes = 512 * 1024", FULL)
        self.assertIn("maximumResponseBytes = 8 * 1024 * 1024", FULL)
        self.assertIn("body.count <= maximumRequestBytes", FULL)
        self.assertIn("result.count <= self.maximumResponseBytes", FULL)
        self.assertIn("Bearer \\(token)", FULL)
        self.assertIn("MAX_WDA_REQUEST = 512 * 1024", SERVER)
        self.assertIn("MAX_WDA_RESPONSE = 8 * 1024 * 1024", SERVER)

    def test_delivery_is_at_most_once_and_root_only(self):
        self.assertIn('command["state"] = "delivered"', SERVER)
        self.assertIn('command.get("state") != "queued"', SERVER)
        self.assertIn("Never repeat an", FULL)
        self.assertIn("mode: int = 0o600", SERVER)
        self.assertIn("state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)", SERVER)
        self.assertIn("never emit request logs", SERVER)

    def test_dark_keypad_recovery_retries_only_read_only_source(self):
        self.assertIn("private let keypadSourceReadAttempts = 5", LOCAL)
        start = LOCAL.index("private func readEmptyPasscodeGate")
        end = LOCAL.index("private func createSession", start)
        helper = LOCAL[start:end]
        self.assertIn('method: "GET", path: "/source"', helper)
        self.assertIn("remaining: remaining - 1", helper)
        self.assertNotIn("sendHID", helper)
        self.assertNotIn("DevicePasscodeStore", helper)
        self.assertNotIn("readSecretAfterBoundary", helper)


if __name__ == "__main__":
    unittest.main(verbosity=2)
