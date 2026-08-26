#!/usr/bin/env python3
"""Policy tests for the v21 metadata-only lifecycle soak monitor."""
from __future__ import annotations

import unittest

from jarvis_v21_lifecycle_soak import (
    EXPECTED_NETWORK,
    EXPECTED_VERSION,
    PROBE_ACTION,
    valid_probe,
)


class V21LifecycleSoakTests(unittest.TestCase):
    def good_result(self) -> dict:
        return {
            "action": PROBE_ACTION,
            "status": "ok",
            "payload": {
                "agent_version": EXPECTED_VERSION,
                "network": EXPECTED_NETWORK,
                "control_error": "none",
                "effect": "probe-only",
                "local_rsd_v4": True,
                "local_rsd_v6": True,
                "local_wda_reachable": True,
                "wda_ready": True,
                "wda_http_status": 200,
                "wda_locked": False,
            },
        }

    def test_only_fixed_read_only_probe_is_used(self) -> None:
        self.assertEqual(PROBE_ACTION, "probe-local-control")
        self.assertTrue(valid_probe(self.good_result()))

    def test_identity_network_and_wda_are_all_required(self) -> None:
        for field, bad_value in (
            ("agent_version", "wrong"),
            ("network", "Wi-Fi"),
            ("control_error", "wda-unreachable"),
            ("effect", "none"),
            ("local_rsd_v4", False),
            ("local_rsd_v6", False),
            ("local_wda_reachable", False),
            ("wda_ready", False),
            ("wda_http_status", 500),
        ):
            result = self.good_result()
            result["payload"][field] = bad_value
            with self.subTest(field=field):
                self.assertFalse(valid_probe(result))

    def test_lock_state_does_not_weaken_probe_validation(self) -> None:
        result = self.good_result()
        result["payload"]["wda_locked"] = True
        self.assertTrue(valid_probe(result))


if __name__ == "__main__":
    unittest.main(verbosity=2)
