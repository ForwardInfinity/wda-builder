#!/usr/bin/env python3
"""Monitor v21 Cellular allocation and integrated WDA without UI or secrets.

The VPS samples authenticated Agent heartbeat metadata and periodically queues
only the fixed, read-only ``probe-local-control`` action.  It never retries a
secret command, reads UI data, or attempts recovery.  Any outage is retained in
root-only state instead of being hidden by an automatic restart.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import time
from pathlib import Path
from typing import Any

from jarvis_agent_server import AgentStore, atomic_json

DEFAULT_STATE_DIR = Path("/var/lib/jarvis-agent")
DEFAULT_ARM_FILE = Path("/run/jarvis-agent-enroll.json")
DEFAULT_OUTPUT = Path("/var/lib/jarvis-agent/v21-lifecycle-soak.json")
EXPECTED_VERSION = "ios-standalone-21r1-full-ui"
EXPECTED_NETWORK = "Cellular"
PROBE_ACTION = "probe-local-control"


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="ascii"))
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, OSError, ValueError, TypeError):
        return {}


def valid_probe(result: dict[str, Any]) -> bool:
    payload = result.get("payload")
    return bool(
        result.get("action") == PROBE_ACTION
        and result.get("status") == "ok"
        and isinstance(payload, dict)
        and payload.get("agent_version") == EXPECTED_VERSION
        and payload.get("network") == EXPECTED_NETWORK
        and payload.get("control_error") == "none"
        and payload.get("effect") == "probe-only"
        and payload.get("local_rsd_v4") is True
        and payload.get("local_rsd_v6") is True
        and payload.get("local_wda_reachable") is True
        and payload.get("wda_ready") is True
        and payload.get("wda_http_status") == 200
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--arm-file", type=Path, default=DEFAULT_ARM_FILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--duration", type=int, default=24 * 60 * 60)
    parser.add_argument("--interval", type=float, default=15.0)
    parser.add_argument("--probe-interval", type=int, default=15 * 60)
    parser.add_argument("--first-probe-delay", type=float, default=30.0)
    parser.add_argument("--fresh-seconds", type=float, default=20.0)
    parser.add_argument("--probe-timeout", type=float, default=90.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if (
        args.duration < 30
        or args.interval <= 0
        or args.probe_interval < 60
        or args.first_probe_delay < 0
        or args.fresh_seconds <= 0
        or args.probe_timeout < 10
    ):
        raise SystemExit("invalid soak bounds")

    os.umask(0o077)
    stop = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    store = AgentStore(args.state_dir, args.arm_file)
    started = time.time()
    deadline = started + args.duration
    next_probe = started + args.first_probe_delay
    pending_id: str | None = None
    pending_since = 0.0
    stale_run_started: float | None = None
    last_fresh = False

    state: dict[str, Any] = {
        "status": "running",
        "passed": False,
        "started_at": started,
        "deadline": deadline,
        "duration_seconds": args.duration,
        "interval_seconds": args.interval,
        "probe_interval_seconds": args.probe_interval,
        "expected_agent_version": EXPECTED_VERSION,
        "expected_network": EXPECTED_NETWORK,
        "samples": 0,
        "fresh_samples": 0,
        "stale_samples": 0,
        "identity_mismatch_samples": 0,
        "network_mismatch_samples": 0,
        "max_age_seconds": 0.0,
        "max_stale_run_seconds": 0.0,
        "recovery_count": 0,
        "probe_queued": 0,
        "probe_passed": 0,
        "probe_failed": 0,
        "probe_skipped": 0,
    }

    while not stop and time.time() < deadline:
        now = time.time()
        heartbeat = read_json(store.heartbeat_file)
        received = heartbeat.get("received_at")
        age = max(0.0, now - float(received)) if isinstance(received, (int, float)) else 1e9
        payload = heartbeat.get("payload") if isinstance(heartbeat.get("payload"), dict) else {}
        identity_ok = payload.get("agent_version") == EXPECTED_VERSION
        network_ok = payload.get("network") == EXPECTED_NETWORK
        fresh = age <= args.fresh_seconds and identity_ok and network_ok

        state["samples"] += 1
        state["max_age_seconds"] = max(float(state["max_age_seconds"]), age)
        state["last_age_seconds"] = age
        state["last_seen"] = received
        state["last_agent_version"] = payload.get("agent_version")
        state["last_network"] = payload.get("network")
        if not identity_ok:
            state["identity_mismatch_samples"] += 1
        if not network_ok:
            state["network_mismatch_samples"] += 1
        if fresh:
            state["fresh_samples"] += 1
            if stale_run_started is not None:
                state["max_stale_run_seconds"] = max(
                    float(state["max_stale_run_seconds"]), now - stale_run_started
                )
                if last_fresh is False:
                    state["recovery_count"] += 1
                stale_run_started = None
        else:
            state["stale_samples"] += 1
            if stale_run_started is None:
                stale_run_started = now
                state.setdefault("first_unhealthy_at", now)
        last_fresh = fresh

        if pending_id is not None:
            result = read_json(store.result_file)
            if result.get("command_id") == pending_id:
                if valid_probe(result):
                    state["probe_passed"] += 1
                else:
                    state["probe_failed"] += 1
                    state.setdefault("first_probe_failure_at", now)
                pending_id = None
            elif now - pending_since > args.probe_timeout:
                state["probe_failed"] += 1
                state.setdefault("first_probe_failure_at", now)
                pending_id = None

        if pending_id is None and now >= next_probe:
            if not fresh:
                state["probe_skipped"] += 1
            else:
                try:
                    command = store.queue_command(PROBE_ACTION)
                except (RuntimeError, ValueError):
                    state["probe_skipped"] += 1
                else:
                    pending_id = str(command["id"])
                    pending_since = now
                    state["probe_queued"] += 1
            next_probe = now + args.probe_interval

        if stale_run_started is not None:
            state["current_stale_run_seconds"] = now - stale_run_started
        else:
            state["current_stale_run_seconds"] = 0.0
        state["pending_probe"] = pending_id is not None
        state["updated_at"] = now
        state["remaining_seconds"] = max(0.0, deadline - now)
        atomic_json(args.output, state)
        time.sleep(args.interval)

    now = time.time()
    if stale_run_started is not None:
        state["max_stale_run_seconds"] = max(
            float(state["max_stale_run_seconds"]), now - stale_run_started
        )
    state["updated_at"] = now
    state["remaining_seconds"] = max(0.0, deadline - now)
    state["pending_probe"] = pending_id is not None
    state["status"] = "stopped" if stop else "completed"
    state["passed"] = bool(
        not stop
        and state["stale_samples"] == 0
        and state["identity_mismatch_samples"] == 0
        and state["network_mismatch_samples"] == 0
        and state["probe_failed"] == 0
        and state["probe_passed"] > 0
        and pending_id is None
    )
    atomic_json(args.output, state)
    print(
        "V21_LIFECYCLE_SOAK_DONE "
        f"status={state['status']} passed={str(state['passed']).lower()} "
        f"samples={state['samples']} probes={state['probe_passed']}/{state['probe_queued']}",
        flush=True,
    )
    # An operator-requested systemd stop is not a monitor failure; the JSON
    # remains passed=false/status=stopped so it cannot be mistaken for a soak pass.
    return 0 if stop or state["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
