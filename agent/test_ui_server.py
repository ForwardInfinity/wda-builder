#!/usr/bin/env python3
import base64
import hashlib
import json
import pathlib
import tempfile
import unittest

from jarvis_ui_server import MAX_WDA_REQUEST, UIStore


class UIStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temp.name)
        self.token = "t" * 48
        self.device = "device-test-123"
        token_file = root / "agent-token.json"
        token_file.write_text(json.dumps({
            "device_id": self.device,
            "token_sha256": hashlib.sha256(self.token.encode()).hexdigest(),
        }))
        token_file.chmod(0o600)
        self.store = UIStore(root / "ui", token_file)

    def tearDown(self):
        self.temp.cleanup()

    def test_auth_is_device_and_token_bound(self):
        self.assertTrue(self.store.authenticate(self.token, self.device))
        self.assertFalse(self.store.authenticate("x" * 48, self.device))
        self.assertFalse(self.store.authenticate(self.token, "other"))

    def test_request_is_delivered_at_most_once(self):
        command_id = self.store.queue("GET", "/source", b"")
        command = self.store.poll(self.device)
        self.assertEqual(command_id, command["id"])
        self.assertIsNone(self.store.poll(self.device))
        with self.assertRaises(RuntimeError):
            self.store.queue("POST", "/wda/homescreen", b"{}")

    def test_matching_bounded_result_completes(self):
        command_id = self.store.queue("GET", "/screenshot", b"")
        self.store.poll(self.device)
        raw = b'{"value":"bounded"}'
        self.store.complete(self.device, {
            "id": command_id,
            "status_code": 200,
            "error": "none",
            "body_b64": base64.b64encode(raw).decode(),
        })
        result = self.store.result(command_id)
        self.assertEqual(raw, base64.b64decode(result["body_b64"]))
        self.assertFalse(self.store.command_file.exists())
        self.assertEqual(0o600, self.store.result_file.stat().st_mode & 0o777)

    def test_mismatch_and_oversize_fail_closed(self):
        command_id = self.store.queue("POST", "/session", b"{}")
        self.store.poll(self.device)
        with self.assertRaises(PermissionError):
            self.store.complete(self.device, {
                "id": "0" * 32,
                "status_code": 200,
                "error": "none",
                "body_b64": "",
            })
        with self.assertRaises(ValueError):
            self.store.queue("POST", "/session", b"x" * (MAX_WDA_REQUEST + 1))
        with self.assertRaises(ValueError):
            self.store.queue("PUT", "/source", b"")
        with self.assertRaises(ValueError):
            self.store.queue("GET", "http://example.invalid", b"")
        self.assertIsNotNone(command_id)


if __name__ == "__main__":
    unittest.main(verbosity=2)
