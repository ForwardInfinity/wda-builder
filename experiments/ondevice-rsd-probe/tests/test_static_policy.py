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
        self.assertIn("ac08b6133eb024eb1a4f06cf25fdd598a79daa72", manifest)
        patch = ROOT / "patches/idevice-verify-only-privacy-and-bounds.patch"
        self.assertEqual(
            hashlib.sha256(patch.read_bytes()).hexdigest(),
            "1ace175b8d25dc12061874fbea6930fdf5006309f6a36eb3aded9edf14201340",
        )
        patch_text = patch.read_text()
        self.assertIn("Never emit it via", patch_text)
        self.assertIn("response body truncated", patch_text)
        self.assertIn('remote_pairing_setup = [', patch_text)
        self.assertIn('dep:rand_core_06', patch_text)
        self.assertNotIn('+  "dep:rsa",\n+]', patch_text)

    def test_ffi_is_narrow_and_fixed_destination(self):
        self.assertIn("Ipv4Addr::new(10, 7, 0, 1)", RUST)
        self.assertIn("49_152", RUST)
        self.assertIn("client.attempt_pair_verify()", RUST)
        self.assertIn("client.validate_pairing(&mut pairing)", RUST)
        self.assertNotRegex(RUST, r"client\.(?:connect|pair)\s*\(")
        exports = re.findall(r'pub unsafe extern "C" fn (jarvis_[a-z0-9_]+)', RUST)
        self.assertEqual(
            exports,
            ["jarvis_rsd_pairing_record_is_valid", "jarvis_rsd_probe"],
        )
        self.assertEqual(RUST.count("#[unsafe(no_mangle)]"), 2)

    def test_header_exposes_no_generic_transport(self):
        functions = re.findall(r"^int32_t (jarvis_[a-z0-9_]+)\(", HEADER, re.MULTILINE)
        self.assertEqual(
            functions,
            ["jarvis_rsd_pairing_record_is_valid", "jarvis_rsd_probe"],
        )
        for forbidden in ("host", "port", "url", "command", "payload", "pin"):
            declarations = "\n".join(
                line for line in HEADER.splitlines() if line.strip().startswith("int32_t")
            ).lower()
            self.assertNotIn(forbidden, declarations)

    def test_swift_network_scope_is_fixed_and_has_no_remote_command_plane(self):
        for forbidden in (
            "URLSession",
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
        self.assertEqual(SWIFT.count("bootstrap.mobiledevicepairing"), 2)
        self.assertIn("removeStagedRecord", SWIFT)

    def test_no_background_mode_or_production_bundle_collision(self):
        self.assertNotIn("UIBackgroundModes", INFO)
        self.assertIn("com.forwardinfinity.jarvisrsdprobe", PROJECT)
        self.assertNotIn("com.forwardinfinity.jarvisagent\n", PROJECT)
        self.assertNotIn("BGTaskScheduler", SWIFT + INFO)

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
