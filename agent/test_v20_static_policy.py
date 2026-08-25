#!/usr/bin/env python3
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
V20 = ROOT / "agent/ios/JarvisAgentV20"
SOURCES = "\n".join(p.read_text() for p in sorted((V20 / "Sources").glob("*.swift")))
INTEGRATED = (V20 / "Sources/IntegratedControllerManager.swift").read_text()
AGENT = (V20 / "Sources/AgentController.swift").read_text()
INFO = (V20 / "Sources/Info.plist").read_text()
PROJECT = (V20 / "project.yml").read_text()


class V20PolicyTests(unittest.TestCase):
    def test_integrated_controller_has_only_fixed_transport(self):
        self.assertEqual(INTEGRATED.count('NWEndpoint.Host("10.7.0.1")'), 1)
        self.assertEqual(INTEGRATED.count("NWEndpoint.Port(rawValue: 49_152)"), 1)
        self.assertEqual(INTEGRATED.count('URL(string: "http://127.0.0.1:8100/status")'), 1)
        self.assertIn("jarvis_rsd_hold_start", INTEGRATED)
        self.assertIn("jarvis_rsd_hold_fixed_wda_start", INTEGRATED)
        self.assertNotIn("baseURL", INTEGRATED)
        for forbidden in ("bundleId", "selector", "payload", "secure-unlock"):
            self.assertNotIn(forbidden, INTEGRATED)

    def test_vps_command_surface_remains_exact(self):
        match = re.search(r"private let allowedCommands = Set\(\[(.*?)\]\)", AGENT, re.S)
        self.assertIsNotNone(match)
        commands = re.findall(r'"([a-z0-9-]+)"', match.group(1))
        self.assertEqual(commands, [
            "ping",
            "probe-local-control",
            "wda-home",
            "wda-launch-settings",
            "wda-continue-recovery",
            "wda-keyboard-probe",
            "secure-unlock",
        ])
        self.assertIn('ios-standalone-20r4-integrated-controller', AGENT)

    def test_pairing_authority_is_device_only(self):
        self.assertIn("AfterFirstUnlockThisDeviceOnly", SOURCES)
        self.assertIn("kSecAttrSynchronizable", SOURCES)
        self.assertIn("jarvis-controller.mobiledevicepairing", INTEGRATED)
        self.assertIn("removeStagedRecord", INTEGRATED)
        self.assertNotIn("pairing", AGENT.lower())
        self.assertNotIn("private_key</key>", SOURCES)

    def test_one_visible_execution_owner(self):
        self.assertEqual(SOURCES.count("BGContinuedProcessingTaskRequest("), 1)
        self.assertIn("One visible 48-hour iOS Continued Processing task owns both", SOURCES)
        self.assertIn("private let overallDuration: TimeInterval = 48 * 60 * 60", SOURCES)
        self.assertIn("private let normalSliceDuration: TimeInterval = 20 * 60", SOURCES)
        self.assertIn("private let initialProofSliceDuration: TimeInterval = 3 * 60", SOURCES)
        self.assertIn("private let maximumRolloverSubmissionAttempts = 3", SOURCES)
        self.assertIn("Rolling visible execution handoff", SOURCES)
        self.assertIn('"jarvis-continued-recovery-allocation-active"', SOURCES)
        self.assertIn('"jarvis-continued-recovery-handoff-count"', SOURCES)
        self.assertIn('"jarvis-continued-recovery-expiration-count"', SOURCES)
        self.assertIn('"allocation-active"', SOURCES)
        self.assertIn('"expiration-callback"', SOURCES)
        successor = SOURCES.index("try BGTaskScheduler.shared.submit(makeRequest(identifier: identifier))", SOURCES.index("private func submitSuccessor"))
        completion = SOURCES.index("oldTask.setTaskCompleted", successor)
        self.assertLess(successor, completion)
        self.assertIn("IntegratedControllerManager.shared.stopForRecoveryExpiration()", SOURCES)
        self.assertIn("private let maximumRecoveryAttempts = 3", INTEGRATED)
        self.assertIn("Controller transport ended", INTEGRATED)
        self.assertIn("timer.schedule(deadline: .now() + 5, repeating: .seconds(5)", INTEGRATED)
        self.assertEqual(INTEGRATED.count("bounded retry"), 1)
        self.assertIn("Cellular retry never depends on fresh fake-peer pair-verify", INTEGRATED)
        self.assertIn("if !self.heldSessionActive", INTEGRATED)
        self.assertIn("com.forwardinfinity.jarvisagent.recovery.*", INFO)
        self.assertNotIn("jarvisrsdprobe.controller", INFO + SOURCES)

    def test_build_scope_and_failed_paths(self):
        self.assertIn("com.forwardinfinity.jarvisagent", PROJECT)
        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET: \"26.0\"", PROJECT)
        self.assertIn("-ljarvis_rsd_probe", PROJECT)
        self.assertFalse((V20 / "Sources/PrivateHIDProbe.swift").exists())
        self.assertFalse((V20 / "Sources/RSDRelayManager.swift").exists())
        for forbidden in (
            "start-rsd-relay",
            "probe-private-hid",
            "probe-tunnel-services",
            "refresh-stream",
        ):
            self.assertNotIn(forbidden, SOURCES)


if __name__ == "__main__":
    unittest.main(verbosity=2)
