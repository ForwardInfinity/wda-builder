#!/usr/bin/env python3
import hashlib
import os
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
RUST = (ROOT / "rust/src/lib.rs").read_text()
SWIFT_FILES = sorted((ROOT / "ios/Sources").glob("*.swift"))
SWIFT = "\n".join(path.read_text() for path in SWIFT_FILES)
HEADER = (ROOT / "include/jarvis_rsd_probe.h").read_text()
PROJECT = (ROOT / "ios/project.yml").read_text()
INFO = (ROOT / "ios/Sources/Info.plist").read_text()


class StaticPolicyTests(unittest.TestCase):
    def test_production_v19_baseline_is_unchanged(self):
        if os.environ.get("JARVIS_SKIP_V19_BASELINE") == "1":
            self.skipTest("builder repository intentionally carries no production artifacts")
        for line in (ROOT / "V19-BASELINE.sha256").read_text().splitlines():
            expected, relative = line.split(None, 1)
            path = REPO / relative.strip()
            self.assertTrue(path.is_file(), relative)
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(actual, expected, relative)

    def test_dependency_is_pinned_and_patch_matches(self):
        manifest = (ROOT / "DEPENDENCIES.lock").read_text()
        self.assertIn("63a341d7f624b5c1f2540e4cecb269151a2caf52", manifest)
        cargo = (ROOT / "rust/Cargo.toml").read_text()
        self.assertIn("lto = false", cargo)
        self.assertIn('strip = "debuginfo"', cargo)
        self.assertEqual(cargo.count('"xctest"'), 1)
        self.assertIn("ac08b6133eb024eb1a4f06cf25fdd598a79daa72", manifest)
        patch = ROOT / "patches/idevice-verify-only-privacy-and-bounds.patch"
        self.assertEqual(
            hashlib.sha256(patch.read_bytes()).hexdigest(),
            "ad5ce44440618e948f0eb403a21fe9146aba156a76269dd0e3e438639e4b78fc",
        )
        patch_text = patch.read_text()
        self.assertIn("Never emit it via", patch_text)
        self.assertIn("response body truncated", patch_text)
        self.assertIn('remote_pairing_setup = [', patch_text)
        self.assertIn('dep:rand_core_06', patch_text)
        self.assertIn('dtx_channel_probe = ["dvt_core", "rsd", "tunnel_tcp_stack"]', patch_text)
        self.assertIn("probe_fixed_testmanager_connections", patch_text)
        self.assertIn("probe_fixed_xctestmanager_proxy_channels", patch_text)
        self.assertEqual(
            patch_text.count(
                '+    "dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface";'
            ),
            1,
        )
        self.assertEqual(
            patch_text.count(".make_channel(XCTEST_MANAGER_PROXY_IDENTIFIER)"),
            2,
        )
        self.assertIn("start_fixed_ondevice_wda_controller", patch_text)
        self.assertEqual(
            patch_text.count(
                '+const FIXED_ONDEVICE_WDA_BUNDLE_ID: &str = "com.ios-use.wda.00008101-00064d1a3a68001e";'
            ),
            1,
        )
        self.assertIn('+        "USE_IP": "127.0.0.1",', patch_text)
        self.assertIn('+        "USE_PORT": "8100",', patch_text)
        self.assertNotIn("+    runner_bundle_id:", patch_text)
        self.assertNotIn("+    target_bundle_id:", patch_text)
        self.assertEqual(patch_text.count('+const TESTMANAGERD: &str = "com.apple.dt.testmanagerd.remote";'), 1)
        self.assertEqual(patch_text.count('+const DTSERVICEHUB: &str = "com.apple.instruments.dtservicehub";'), 1)
        self.assertNotIn("+pub mod process_control;", patch_text)
        self.assertNotIn("+pub mod screenshot;", patch_text)
        self.assertNotIn("+pub mod xctest;", patch_text)
        self.assertNotIn('+  "dep:rsa",\n+]', patch_text)

    def test_ffi_is_narrow_and_fixed_destination(self):
        self.assertIn("Ipv4Addr::new(10, 7, 0, 1)", RUST)
        self.assertIn("49_152", RUST)
        self.assertIn("client.attempt_pair_verify()", RUST)
        self.assertIn("client.validate_pairing(&mut pairing)", RUST)
        self.assertNotRegex(RUST, r"client\.(?:connect|pair)\s*\(")
        exports = re.findall(r'pub (?:unsafe )?extern "C" fn (jarvis_[a-z0-9_]+)', RUST)
        self.assertEqual(
            exports,
            [
                "jarvis_rsd_pairing_record_is_valid",
                "jarvis_rsd_probe",
                "jarvis_rsd_hold_start",
                "jarvis_rsd_hold_check",
                "jarvis_rsd_hold_dtx_probe",
                "jarvis_rsd_hold_xctestmanager_proxy_probe",
                "jarvis_rsd_hold_fixed_wda_start",
                "jarvis_rsd_fixed_wda_progress",
                "jarvis_rsd_fixed_wda_check",
                "jarvis_rsd_fixed_wda_stop",
                "jarvis_rsd_hold_stop",
            ],
        )
        self.assertEqual(RUST.count("#[unsafe(no_mangle)]"), 11)
        self.assertIn("HELD_SESSION_MAX_AGE", RUST)
        self.assertIn("Duration::from_secs(10 * 60)", RUST)

    def test_header_exposes_no_generic_transport(self):
        functions = re.findall(
            r"^(?:int32_t|uint32_t) (jarvis_[a-z0-9_]+)\(", HEADER, re.MULTILINE
        )
        self.assertEqual(
            functions,
            [
                "jarvis_rsd_pairing_record_is_valid",
                "jarvis_rsd_probe",
                "jarvis_rsd_hold_start",
                "jarvis_rsd_hold_check",
                "jarvis_rsd_hold_dtx_probe",
                "jarvis_rsd_hold_xctestmanager_proxy_probe",
                "jarvis_rsd_hold_fixed_wda_start",
                "jarvis_rsd_fixed_wda_progress",
                "jarvis_rsd_fixed_wda_check",
                "jarvis_rsd_fixed_wda_stop",
                "jarvis_rsd_hold_stop",
            ],
        )
        for forbidden in ("host", "port", "url", "command", "payload", "pin"):
            declarations = "\n".join(
                line for line in HEADER.splitlines() if line.strip().startswith("int32_t")
            ).lower()
            self.assertNotIn(forbidden, declarations)

    def test_swift_network_scope_is_fixed_and_has_no_remote_command_plane(self):
        for forbidden in (
            "NWBrowser",
            "NWListener",
            "NWEndpoint.Service",
            "workbox.tailfd8ac6.ts.net",
            "/v1/",
            "secure-unlock",
            "performIoHidEvent",
            "localhost:8100",
        ):
            self.assertNotIn(forbidden, SWIFT)
        self.assertEqual(SWIFT.count("NWConnection("), 1)
        self.assertEqual(SWIFT.count('NWEndpoint.Host("10.7.0.1")'), 1)
        self.assertEqual(SWIFT.count("NWEndpoint.Port(rawValue: 49_152)"), 1)
        self.assertIn("Request Local Network access", SWIFT)
        self.assertIn("NSLocalNetworkUsageDescription", INFO)
        self.assertIn("AfterFirstUnlockThisDeviceOnly", SWIFT)
        self.assertIn("kSecAttrSynchronizable", SWIFT)
        self.assertIn("Run read-only RSD probe", SWIFT)
        self.assertIn("Start held read-only RSD session", SWIFT)
        self.assertIn("This is not cold recoverability", SWIFT)
        self.assertIn("Probe three fixed DTX transports", SWIFT)
        self.assertIn("does not open a DTX service channel", SWIFT)
        self.assertIn("Probe two fixed proxy channels", SWIFT)
        self.assertIn("sends no XCTest session-init", SWIFT)
        self.assertEqual(SWIFT.count('URL(string: "http://127.0.0.1:8100/status")'), 1)
        self.assertIn("Start protected local controller + WDA", SWIFT)
        self.assertIn("real iOS system prompt directly on-device", SWIFT)
        self.assertIn("NSAllowsLocalNetworking", INFO)
        self.assertNotIn("launch_runner", RUST + SWIFT + HEADER)
        self.assertNotIn("authorize_test", RUST + SWIFT + HEADER)
        self.assertEqual(SWIFT.count("bootstrap.mobiledevicepairing"), 2)
        self.assertIn("removeStagedRecord", SWIFT)

    def test_only_user_visible_continued_processing_is_present(self):
        self.assertNotIn("UIBackgroundModes", INFO)
        self.assertIn("com.forwardinfinity.jarvisrsdprobe", PROJECT)
        self.assertNotIn("com.forwardinfinity.jarvisagent\n", PROJECT)
        self.assertEqual(
            INFO.count("com.forwardinfinity.jarvisrsdprobe.controller.*"),
            1,
        )
        self.assertEqual(SWIFT.count("BGContinuedProcessingTaskRequest("), 1)
        self.assertEqual(SWIFT.count("startFromUserAction()"), 2)
        self.assertIn("visible iOS 48-hour continued-processing grant", SWIFT)
        self.assertIn("Cold restore rejected — controller handles absent", SWIFT)
        for forbidden in (
            "BGAppRefreshTask",
            "BGProcessingTaskRequest",
            "URLSessionConfiguration.background",
            "beginBackgroundTask",
        ):
            self.assertNotIn(forbidden, SWIFT)

    def test_no_pairing_material_is_committed(self):
        allowed_plists = {ROOT / "ios/Sources/Info.plist"}
        candidates = []
        for suffix in ("*.mobiledevicepairing", "*.mobiledevicepair", "*.plist"):
            candidates.extend(path for path in ROOT.rglob(suffix) if "vendor" not in path.parts)
        self.assertEqual(set(candidates), allowed_plists)
        executable_sources = RUST + SWIFT + HEADER + INFO + PROJECT
        self.assertNotIn("159357", executable_sources)
        self.assertNotIn("private_key</key>", executable_sources)


if __name__ == "__main__":
    unittest.main(verbosity=2)
