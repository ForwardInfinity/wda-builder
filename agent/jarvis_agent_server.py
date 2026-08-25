#!/usr/bin/env python3
"""Authenticated reverse-agent rendezvous for Jarvis WDA.

The iPhone initiates every request, so this channel can reconnect on cellular
without opening an inbound port on iOS.  No passcode, pairing record, ntfy topic,
or UI data is accepted. The command plane is a fixed action allowlist and only
stores bounded health/control outcome metadata.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_STATE_DIR = Path("/var/lib/jarvis-agent")
DEFAULT_ARM_FILE = Path("/run/jarvis-agent-enroll.json")
MAX_BODY = 8192
MAX_RELAY_CHUNK = 64 * 1024
MAX_RELAY_BUFFER = 1024 * 1024
DEFAULT_RELAY_PORT = 49153
DEFAULT_RELAY_WAIT_SECONDS = 8.0
MAX_ARM_SECONDS = 120
DEFAULT_LEASE_SECONDS = 20.0
DEFAULT_STREAM_INTERVAL = 10.0
DEFAULT_STREAM_CHUNK_BYTES = 128
DEFAULT_STREAM_TOTAL_BYTES = 8 * 1024 * 1024
STREAM_PATTERN = b"JARVIS-BACKGROUND-STREAM-1\n"
PROTOCOL_VERSION = 1
# Production command surface. Failed v14-v18 relay/tunnel/private-HID
# experiments remain available only in source history and cannot be queued.
ALLOWED_COMMANDS = {
    "ping",
    "probe-local-control",
    "wda-home",
    "wda-launch-settings",
    "wda-continue-recovery",
    "wda-keyboard-probe",
    "secure-unlock",
}
ALLOWED_RESULT_STATUS = {"ok", "error"}
CONTROL_BOOL_FIELDS = {
    "local_wda_reachable",
    "wda_ready",
    "wda_locked",
    "local_rsd_v4",
    "local_rsd_v6",
    "keypad_gate",
    "probe_digit_sent",
    "cleanup_sent",
    "secret_accessed",
    "unlock_verified",
}
ALLOWED_CONTROL_EFFECTS = {
    "none",
    "probe-only",
    "home-sent",
    "settings-launch-sent",
    "recovery-continued",
    "keyboard-probe-cleaned",
    "unlock-sent",
    "unlocked",
}
ALLOWED_CONTROL_ERRORS = {
    "none",
    "unsupported-action",
    "wda-unreachable",
    "wda-http-error",
    "ambiguous-state",
    "journal-unavailable",
    "journal-completion-failed",
    "session-failed",
    "element-not-found",
    "device-not-locked",
    "keypad-gate-rejected",
    "hid-rejected",
    "passcode-not-provisioned",
    "gate-file-failed",
    "secret-marker-failed",
    "unlock-not-verified",
}


def atomic_json(path: Path, value: dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, separators=(",", ":"), sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


class AgentStore:
    def __init__(self, state_dir: Path, arm_file: Path) -> None:
        self.state_dir = state_dir
        self.arm_file = arm_file
        self.token_file = state_dir / "token.json"
        self.heartbeat_file = state_dir / "heartbeat.json"
        self.command_file = state_dir / "command.json"
        self.result_file = state_dir / "result.json"
        self._lock = threading.Lock()
        self._active_streams: set[str] = set()

    def arm(self, seconds: int) -> None:
        if not 1 <= seconds <= MAX_ARM_SECONDS:
            raise ValueError(f"seconds must be in 1..{MAX_ARM_SECONDS}")
        atomic_json(
            self.arm_file,
            {"armed_at": time.time(), "expires_at": time.time() + seconds},
        )

    def consume_arm(self) -> None:
        with self._lock:
            try:
                raw = self.arm_file.read_text(encoding="ascii")
                gate = json.loads(raw)
            except (FileNotFoundError, OSError, ValueError, TypeError) as exc:
                raise PermissionError("enrollment is not armed") from exc
            # Consume before issuing or returning any credential.
            self.arm_file.unlink(missing_ok=True)
            expires_at = gate.get("expires_at")
            if not isinstance(expires_at, (int, float)) or time.time() > expires_at:
                raise PermissionError("enrollment window expired")

    def enroll(self, device_id: str) -> str:
        if not (8 <= len(device_id) <= 128):
            raise ValueError("invalid device_id")
        self.consume_arm()
        token = secrets.token_urlsafe(32)
        atomic_json(
            self.token_file,
            {
                "device_id": device_id,
                "token_sha256": hashlib.sha256(token.encode("ascii")).hexdigest(),
                "issued_at": time.time(),
                "protocol": PROTOCOL_VERSION,
            },
        )
        return token

    def authenticate(self, token: str, device_id: str) -> bool:
        try:
            record = json.loads(self.token_file.read_text(encoding="ascii"))
            expected = record["token_sha256"]
            bound_device = record["device_id"]
        except (FileNotFoundError, OSError, ValueError, KeyError, TypeError):
            return False
        actual = hashlib.sha256(token.encode("utf-8")).hexdigest()
        return hmac.compare_digest(actual, expected) and hmac.compare_digest(device_id, bound_device)

    def heartbeat(self, device_id: str, payload: dict[str, Any], remote: str) -> None:
        # Explicit allowlist: phase 1 never stores screenshots, UI trees, or secrets.
        allowed: dict[str, Any] = {}
        for key in (
            "protocol",
            "uptime",
            "bundle",
            "os",
            "agent_version",
            "channel",
            "lease_phase",
            "stream_phase",
            "stream_offset",
            "range_resumed",
            "network",
        ):
            value = payload.get(key)
            if isinstance(value, (str, int, float, bool)):
                allowed[key] = value
        atomic_json(
            self.heartbeat_file,
            {
                "device_id": device_id,
                "received_at": time.time(),
                "remote": remote,
                "payload": allowed,
            },
        )

    def queue_command(self, action: str) -> dict[str, Any]:
        if action not in ALLOWED_COMMANDS:
            raise ValueError("unsupported command")
        with self._lock:
            if self.command_file.exists():
                raise RuntimeError("an unacknowledged command already exists")
            try:
                token_record = json.loads(self.token_file.read_text(encoding="ascii"))
                device_id = token_record["device_id"]
            except (FileNotFoundError, OSError, ValueError, KeyError, TypeError) as exc:
                raise RuntimeError("no enrolled device") from exc
            command = {
                "id": secrets.token_hex(16),
                "action": action,
                "device_id": device_id,
                "queued_at": time.time(),
                "protocol": PROTOCOL_VERSION,
            }
            atomic_json(self.command_file, command)
            return command

    def pending_command(self, device_id: str) -> dict[str, Any] | None:
        with self._lock:
            try:
                command = json.loads(self.command_file.read_text(encoding="ascii"))
            except (FileNotFoundError, OSError, ValueError, TypeError):
                return None
            if command.get("device_id") != device_id or command.get("action") not in ALLOWED_COMMANDS:
                return None
            command_id = command.get("id")
            if not isinstance(command_id, str) or len(command_id) != 32:
                return None
            return {"id": command_id, "action": command["action"]}

    def complete_command(self, device_id: str, payload: dict[str, Any], remote: str) -> None:
        command_id = payload.get("command_id")
        action = payload.get("action")
        status = payload.get("status")
        if not isinstance(command_id, str) or len(command_id) != 32:
            raise ValueError("invalid command_id")
        if action not in ALLOWED_COMMANDS or status not in ALLOWED_RESULT_STATUS:
            raise ValueError("invalid command result")
        with self._lock:
            try:
                command = json.loads(self.command_file.read_text(encoding="ascii"))
            except (FileNotFoundError, OSError, ValueError, TypeError) as exc:
                raise PermissionError("no pending command") from exc
            if (
                command.get("device_id") != device_id
                or not hmac.compare_digest(str(command.get("id", "")), command_id)
                or command.get("action") != action
            ):
                raise PermissionError("command result mismatch")
            allowed: dict[str, Any] = {}
            for key in ("agent_version", "network", "uptime"):
                value = payload.get(key)
                if isinstance(value, (str, int, float, bool)):
                    allowed[key] = value
            for key in CONTROL_BOOL_FIELDS:
                value = payload.get(key)
                if value is not None:
                    if type(value) is not bool:
                        raise ValueError(f"invalid {key}")
                    allowed[key] = value
            http_status = payload.get("wda_http_status")
            if http_status is not None:
                if type(http_status) is not int or not 0 <= http_status <= 599:
                    raise ValueError("invalid wda_http_status")
                allowed["wda_http_status"] = http_status
            effect = payload.get("effect")
            if effect is not None:
                if effect not in ALLOWED_CONTROL_EFFECTS:
                    raise ValueError("invalid effect")
                allowed["effect"] = effect
            control_error = payload.get("control_error")
            if control_error is not None:
                if control_error not in ALLOWED_CONTROL_ERRORS:
                    raise ValueError("invalid control_error")
                allowed["control_error"] = control_error
            atomic_json(
                self.result_file,
                {
                    "device_id": device_id,
                    "command_id": command_id,
                    "action": action,
                    "status": status,
                    "received_at": time.time(),
                    "remote": remote,
                    "payload": allowed,
                },
            )
            self.command_file.unlink(missing_ok=True)

    def begin_stream(self, device_id: str) -> bool:
        with self._lock:
            if device_id in self._active_streams:
                return False
            self._active_streams.add(device_id)
            return True

    def end_stream(self, device_id: str) -> None:
        with self._lock:
            self._active_streams.discard(device_id)

    def status(self) -> dict[str, Any]:
        result: dict[str, Any] = {"enrolled": self.token_file.exists()}
        result["command_pending"] = self.command_file.exists()
        try:
            command = json.loads(self.command_file.read_text(encoding="ascii"))
            result["command"] = {
                "id": command.get("id"),
                "action": command.get("action"),
                "queued_at": command.get("queued_at"),
            }
        except (FileNotFoundError, OSError, ValueError, TypeError):
            pass
        try:
            command_result = json.loads(self.result_file.read_text(encoding="ascii"))
            result["last_result"] = {
                key: command_result.get(key)
                for key in ("command_id", "action", "status", "received_at", "payload")
            }
        except (FileNotFoundError, OSError, ValueError, TypeError):
            pass
        try:
            heartbeat = json.loads(self.heartbeat_file.read_text(encoding="ascii"))
            result.update(
                {
                    "last_seen": heartbeat.get("received_at"),
                    "age_seconds": max(0.0, time.time() - float(heartbeat["received_at"])),
                    "device_id": heartbeat.get("device_id"),
                    "payload": heartbeat.get("payload", {}),
                }
            )
        except (FileNotFoundError, OSError, ValueError, KeyError, TypeError):
            result["last_seen"] = None
        return result


class RSDRelayBroker:
    """One authenticated, fixed iPhone-loopback RSD byte stream.

    The public HTTPS side is split into bounded upload and long-poll download
    requests. A single localhost-only holder connects to ``listen_port`` and
    runs the fixed WDA/XCTest lifecycle. No relay bytes are written to disk.
    """

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = DEFAULT_RELAY_PORT,
        max_buffer: int = MAX_RELAY_BUFFER,
    ) -> None:
        self.max_buffer = max_buffer
        self._condition = threading.Condition()
        self._send_lock = threading.Lock()
        self._stopping = False
        self._device_id: str | None = None
        self._nonce: str | None = None
        self._relay_id: str | None = None
        self._holder: socket.socket | None = None
        self._broken = False
        self._to_agent = bytearray()
        self._to_holder = bytearray()
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind((host, port))
        self._listener.listen(1)
        self._listener.settimeout(0.5)
        self.listen_host, self.listen_port = self._listener.getsockname()
        self._accept_thread = threading.Thread(target=self._accept_loop, name="jarvis-rsd-relay", daemon=True)
        self._accept_thread.start()

    @staticmethod
    def _valid_id(value: str) -> bool:
        return re.fullmatch(r"[0-9a-f]{32}", value) is not None

    def open(self, device_id: str, nonce: str) -> str:
        if not self._valid_id(nonce):
            raise ValueError("invalid relay nonce")
        with self._condition:
            if (
                self._device_id == device_id
                and self._nonce == nonce
                and self._relay_id is not None
                and not self._broken
            ):
                return self._relay_id
            self._reset_locked()
            self._device_id = device_id
            self._nonce = nonce
            self._relay_id = secrets.token_hex(16)
            self._condition.notify_all()
            return self._relay_id

    def close_relay(self, device_id: str, relay_id: str) -> None:
        with self._condition:
            self._validate_locked(device_id, relay_id)
            self._reset_locked()
            self._condition.notify_all()

    def upload(self, device_id: str, relay_id: str, data: bytes) -> None:
        if not 0 < len(data) <= MAX_RELAY_CHUNK:
            raise ValueError("invalid relay chunk size")
        with self._condition:
            self._validate_locked(device_id, relay_id)
            if self._broken:
                raise RuntimeError("relay holder disconnected")
            holder = self._holder
            if holder is None:
                if len(self._to_holder) + len(data) > self.max_buffer:
                    self._mark_broken_locked()
                    raise RuntimeError("relay upstream buffer exceeded")
                self._to_holder.extend(data)
                return
        try:
            with self._send_lock:
                holder.sendall(data)
        except OSError as exc:
            with self._condition:
                if self._holder is holder:
                    self._mark_broken_locked()
            raise RuntimeError("relay holder disconnected") from exc

    def download(self, device_id: str, relay_id: str, timeout: float) -> bytes:
        deadline = time.monotonic() + timeout
        with self._condition:
            self._validate_locked(device_id, relay_id)
            while not self._to_agent:
                if self._broken:
                    raise RuntimeError("relay holder disconnected")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return b""
                self._condition.wait(remaining)
                self._validate_locked(device_id, relay_id)
            size = min(MAX_RELAY_CHUNK, len(self._to_agent))
            result = bytes(self._to_agent[:size])
            del self._to_agent[:size]
            return result

    def _validate_locked(self, device_id: str, relay_id: str) -> None:
        if not self._valid_id(relay_id) or self._device_id != device_id or self._relay_id != relay_id:
            raise PermissionError("relay session mismatch")

    def _accept_loop(self) -> None:
        while not self._stopping:
            try:
                holder, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            holder.settimeout(None)
            pending = b""
            with self._condition:
                if self._relay_id is None or self._holder is not None or self._broken:
                    holder.close()
                    continue
                self._holder = holder
                pending = bytes(self._to_holder)
                self._to_holder.clear()
                self._condition.notify_all()
            try:
                if pending:
                    with self._send_lock:
                        holder.sendall(pending)
            except OSError:
                with self._condition:
                    if self._holder is holder:
                        self._mark_broken_locked()
                continue
            threading.Thread(
                target=self._read_holder,
                args=(holder,),
                name="jarvis-rsd-relay-reader",
                daemon=True,
            ).start()

    def _read_holder(self, holder: socket.socket) -> None:
        try:
            while True:
                data = holder.recv(MAX_RELAY_CHUNK)
                if not data:
                    break
                with self._condition:
                    if self._holder is not holder or self._relay_id is None:
                        return
                    if len(self._to_agent) + len(data) > self.max_buffer:
                        self._mark_broken_locked()
                        return
                    self._to_agent.extend(data)
                    self._condition.notify_all()
        except OSError:
            pass
        finally:
            with self._condition:
                if self._holder is holder:
                    self._mark_broken_locked()

    def _mark_broken_locked(self) -> None:
        self._broken = True
        holder, self._holder = self._holder, None
        if holder is not None:
            try:
                holder.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            holder.close()
        self._condition.notify_all()

    def _reset_locked(self) -> None:
        holder, self._holder = self._holder, None
        if holder is not None:
            try:
                holder.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            holder.close()
        self._device_id = None
        self._nonce = None
        self._relay_id = None
        self._broken = False
        self._to_agent.clear()
        self._to_holder.clear()

    def close(self) -> None:
        self._stopping = True
        try:
            self._listener.close()
        except OSError:
            pass
        with self._condition:
            self._reset_locked()
            self._condition.notify_all()
        self._accept_thread.join(timeout=2)


class AgentHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        store: AgentStore,
        lease_seconds: float = DEFAULT_LEASE_SECONDS,
        stream_interval: float = DEFAULT_STREAM_INTERVAL,
        stream_chunk_bytes: int = DEFAULT_STREAM_CHUNK_BYTES,
        stream_total_bytes: int = DEFAULT_STREAM_TOTAL_BYTES,
        enable_legacy_transport: bool = False,
        enable_rsd_relay: bool = False,
        rsd_relay_host: str = "127.0.0.1",
        rsd_relay_port: int = DEFAULT_RELAY_PORT,
        rsd_relay_wait_seconds: float = DEFAULT_RELAY_WAIT_SECONDS,
    ):
        super().__init__(address, AgentHandler)
        self.rsd_relay: RSDRelayBroker | None = None
        if enable_rsd_relay:
            try:
                self.rsd_relay = RSDRelayBroker(rsd_relay_host, rsd_relay_port)
            except BaseException:
                super().server_close()
                raise
        self.store = store
        self.enable_legacy_transport = enable_legacy_transport
        self.lease_seconds = lease_seconds
        self.stream_interval = stream_interval
        self.stream_chunk_bytes = stream_chunk_bytes
        self.stream_total_bytes = stream_total_bytes
        self.rsd_relay_wait_seconds = rsd_relay_wait_seconds

    def server_close(self) -> None:
        if self.rsd_relay is not None:
            self.rsd_relay.close()
        super().server_close()


class AgentHandler(BaseHTTPRequestHandler):
    server: AgentHTTPServer
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        # BaseHTTPRequestHandler never includes request headers here. Keep the
        # log useful while guaranteeing Authorization is not printed.
        print(f"agent_http remote={self.client_address[0]} {fmt % args}", flush=True)

    def _json_body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid content length") from exc
        if not 0 < length <= MAX_BODY:
            raise ValueError("invalid body size")
        try:
            value = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("invalid JSON") from exc
        if not isinstance(value, dict):
            raise ValueError("JSON object required")
        return value

    def _send_json(self, status: HTTPStatus, value: dict[str, Any]) -> None:
        data = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _binary_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid content length") from exc
        if not 0 < length <= MAX_RELAY_CHUNK:
            raise ValueError("invalid relay chunk size")
        return self.rfile.read(length)

    def _send_binary(self, value: bytes) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(value)))
        self.send_header("Cache-Control", "no-store, no-transform")
        self.send_header("X-Accel-Buffering", "no")
        # Funnel does not consistently complete zero-length long-poll responses
        # until the backend connection closes, despite Content-Length: 0.
        self.send_header("Connection", "close")
        self.end_headers()
        if value:
            self.wfile.write(value)

    def do_GET(self) -> None:  # noqa: N802
        try:
            if self.path == "/healthz":
                self._send_json(HTTPStatus.OK, {"ok": True, "protocol": PROTOCOL_VERSION})
                return
            if self.path == "/v1/lease":
                if self.server.enable_legacy_transport:
                    self._lease()
                else:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            if self.path == "/v1/stream":
                if self.server.enable_legacy_transport:
                    self._stream()
                else:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            if self.path == "/v1/rsd-relay/down":
                if self.server.rsd_relay is None:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                else:
                    self._relay_down()
                return
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except PermissionError as exc:
            self._send_json(HTTPStatus.FORBIDDEN, {"error": str(exc)})
        except RuntimeError as exc:
            self._send_json(HTTPStatus.CONFLICT, {"error": str(exc)})
        except ConnectionAbortedError:
            return

    def do_POST(self) -> None:  # noqa: N802
        try:
            if self.path.startswith("/v1/rsd-relay/") and self.server.rsd_relay is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            if self.path == "/v1/rsd-relay/up":
                self._relay_up()
                return
            body = self._json_body()
            if self.path == "/v1/enroll":
                self._enroll(body)
                return
            if self.path == "/v1/heartbeat":
                self._heartbeat(body)
                return
            if self.path == "/v1/result":
                self._result(body)
                return
            if self.path == "/v1/rsd-relay/open":
                self._relay_open(body)
                return
            if self.path == "/v1/rsd-relay/close":
                self._relay_close(body)
                return
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except PermissionError as exc:
            self._send_json(HTTPStatus.FORBIDDEN, {"error": str(exc)})
        except RuntimeError as exc:
            self._send_json(HTTPStatus.CONFLICT, {"error": str(exc)})

    def _device_id(self, body: dict[str, Any]) -> str:
        device_id = body.get("device_id")
        if not isinstance(device_id, str) or not (8 <= len(device_id) <= 128):
            raise ValueError("invalid device_id")
        return device_id

    def _enroll(self, body: dict[str, Any]) -> None:
        if body.get("client") != "jarvis-wda" or body.get("protocol") != PROTOCOL_VERSION:
            raise ValueError("unsupported client")
        token = self.server.store.enroll(self._device_id(body))
        self._send_json(
            HTTPStatus.OK,
            {"token": token, "protocol": PROTOCOL_VERSION, "heartbeat_seconds": 5},
        )

    def _authenticated_device(self, device_id: str) -> str:
        if not (8 <= len(device_id) <= 128):
            raise ValueError("invalid device_id")
        authorization = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not authorization.startswith(prefix):
            raise PermissionError("authentication required")
        token = authorization[len(prefix) :]
        if not self.server.store.authenticate(token, device_id):
            raise PermissionError("authentication failed")
        return self.headers.get("X-Forwarded-For", self.client_address[0]).split(",", 1)[0].strip()

    def _heartbeat(self, body: dict[str, Any]) -> None:
        device_id = self._device_id(body)
        remote = self._authenticated_device(device_id)
        self.server.store.heartbeat(device_id, body, remote)
        response: dict[str, Any] = {"ok": True, "next_poll_seconds": 5}
        command = self.server.store.pending_command(device_id)
        if command is not None:
            response["command"] = command
        self._send_json(HTTPStatus.OK, response)

    def _result(self, body: dict[str, Any]) -> None:
        device_id = self._device_id(body)
        remote = self._authenticated_device(device_id)
        self.server.store.complete_command(device_id, body, remote)
        self._send_json(HTTPStatus.OK, {"ok": True})

    def _relay_headers(self) -> tuple[str, str]:
        device_id = self.headers.get("X-Jarvis-Device-ID", "")
        self._authenticated_device(device_id)
        relay_id = self.headers.get("X-Jarvis-Relay-ID", "")
        return device_id, relay_id

    def _relay_open(self, body: dict[str, Any]) -> None:
        device_id = self._device_id(body)
        self._authenticated_device(device_id)
        if body.get("protocol") != PROTOCOL_VERSION:
            raise ValueError("unsupported relay protocol")
        nonce = body.get("nonce")
        if not isinstance(nonce, str):
            raise ValueError("invalid relay nonce")
        relay = self.server.rsd_relay
        if relay is None:
            raise RuntimeError("relay disabled")
        relay_id = relay.open(device_id, nonce)
        self._send_json(
            HTTPStatus.OK,
            {
                "ok": True,
                "relay_id": relay_id,
                "max_chunk_bytes": MAX_RELAY_CHUNK,
                "down_wait_seconds": self.server.rsd_relay_wait_seconds,
            },
        )

    def _relay_up(self) -> None:
        device_id, relay_id = self._relay_headers()
        data = self._binary_body()
        relay = self.server.rsd_relay
        if relay is None:
            raise RuntimeError("relay disabled")
        relay.upload(device_id, relay_id, data)
        self._send_binary(b"")

    def _relay_down(self) -> None:
        device_id, relay_id = self._relay_headers()
        relay = self.server.rsd_relay
        if relay is None:
            raise RuntimeError("relay disabled")
        data = relay.download(device_id, relay_id, self.server.rsd_relay_wait_seconds)
        self._send_binary(data)

    def _relay_close(self, body: dict[str, Any]) -> None:
        device_id = self._device_id(body)
        self._authenticated_device(device_id)
        relay_id = body.get("relay_id")
        if not isinstance(relay_id, str):
            raise ValueError("invalid relay id")
        relay = self.server.rsd_relay
        if relay is None:
            raise RuntimeError("relay disabled")
        relay.close_relay(device_id, relay_id)
        self._send_json(HTTPStatus.OK, {"ok": True})

    def _lease(self) -> None:
        device_id = self.headers.get("X-Jarvis-Device-ID", "")
        remote = self._authenticated_device(device_id)
        version = self.headers.get("X-Jarvis-Agent-Version", "ios-background-lease-1")
        base_payload = {
            "protocol": PROTOCOL_VERSION,
            "agent_version": version,
            "channel": "background-download",
        }
        self.server.store.heartbeat(device_id, {**base_payload, "lease_phase": "accepted"}, remote)
        time.sleep(self.server.lease_seconds)
        self.server.store.heartbeat(device_id, {**base_payload, "lease_phase": "completed"}, remote)
        self._send_json(
            HTTPStatus.OK,
            {"ok": True, "sequence": int(time.time() * 1000), "next_poll_seconds": 0},
        )

    def _stream_range_start(self, total: int) -> tuple[int, bool]:
        value = self.headers.get("Range")
        if value is None:
            return 0, False
        match = re.fullmatch(r"bytes=(\d+)-", value.strip())
        if match is None:
            raise ValueError("unsupported range")
        start = int(match.group(1))
        if not 0 <= start < total:
            self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            self.send_header("Content-Range", f"bytes */{total}")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            raise ConnectionAbortedError("range not satisfiable")
        return start, True

    @staticmethod
    def _stream_bytes(offset: int, length: int) -> bytes:
        pattern = STREAM_PATTERN
        return bytes(pattern[(offset + index) % len(pattern)] for index in range(length))

    def _stream(self) -> None:
        device_id = self.headers.get("X-Jarvis-Device-ID", "")
        remote = self._authenticated_device(device_id)
        version = self.headers.get("X-Jarvis-Agent-Version", "ios-background-stream-1")
        total = self.server.stream_total_bytes
        start, resumed = self._stream_range_start(total)
        if not self.server.store.begin_stream(device_id):
            self._send_json(HTTPStatus.CONFLICT, {"error": "stream already active"})
            return
        network = self.headers.get("X-Jarvis-Network", "Unknown")
        if network not in {"Cellular", "Wi-Fi", "Ethernet", "Other", "Offline", "Unknown"}:
            network = "Unknown"
        base_payload = {
            "protocol": PROTOCOL_VERSION,
            "agent_version": version,
            "channel": "background-stream",
            "range_resumed": resumed,
            "network": network,
        }
        offset = start
        try:
            status = HTTPStatus.PARTIAL_CONTENT if resumed else HTTPStatus.OK
            self.send_response(status)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(total - start))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", f'"jarvis-stream-v1-{total}"')
            self.send_header("Cache-Control", "no-store, no-transform")
            self.send_header("X-Accel-Buffering", "no")
            if resumed:
                self.send_header("Content-Range", f"bytes {start}-{total - 1}/{total}")
            self.end_headers()
            self.server.store.heartbeat(
                device_id,
                {**base_payload, "stream_phase": "accepted", "stream_offset": offset},
                remote,
            )
            while offset < total:
                count = min(self.server.stream_chunk_bytes, total - offset)
                self.wfile.write(self._stream_bytes(offset, count))
                self.wfile.flush()
                offset += count
                self.server.store.heartbeat(
                    device_id,
                    {**base_payload, "stream_phase": "tick", "stream_offset": offset},
                    remote,
                )
                if offset < total:
                    time.sleep(self.server.stream_interval)
            self.server.store.heartbeat(
                device_id,
                {**base_payload, "stream_phase": "completed", "stream_offset": offset},
                remote,
            )
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            try:
                self.server.store.heartbeat(
                    device_id,
                    {**base_payload, "stream_phase": "disconnected", "stream_offset": offset},
                    remote,
                )
            except OSError:
                pass
            self.close_connection = True
        finally:
            self.server.store.end_stream(device_id)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--arm-file", type=Path, default=DEFAULT_ARM_FILE)
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--bind", default=DEFAULT_BIND)
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve.add_argument("--lease-seconds", type=float, default=DEFAULT_LEASE_SECONDS)
    serve.add_argument("--stream-interval", type=float, default=DEFAULT_STREAM_INTERVAL)
    serve.add_argument("--stream-chunk-bytes", type=int, default=DEFAULT_STREAM_CHUNK_BYTES)
    serve.add_argument("--stream-total-bytes", type=int, default=DEFAULT_STREAM_TOTAL_BYTES)
    serve.add_argument(
        "--enable-legacy-transport",
        action="store_true",
        help="enable superseded lease/stream experiments (disabled by default)",
    )
    serve.add_argument(
        "--enable-rsd-relay",
        action="store_true",
        help="enable quarantined experimental relay (disabled by default)",
    )
    serve.add_argument("--rsd-relay-host", default="127.0.0.1")
    serve.add_argument("--rsd-relay-port", type=int, default=DEFAULT_RELAY_PORT)
    serve.add_argument("--rsd-relay-wait-seconds", type=float, default=DEFAULT_RELAY_WAIT_SECONDS)
    arm = sub.add_parser("arm")
    arm.add_argument("--seconds", type=int, default=60)
    queue = sub.add_parser("queue")
    queue.add_argument("--action", required=True, choices=sorted(ALLOWED_COMMANDS))
    sub.add_parser("status")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    store = AgentStore(args.state_dir, args.arm_file)
    if args.command == "arm":
        store.arm(args.seconds)
        print(f"ENROLLMENT_ARMED seconds={args.seconds}")
        return
    if args.command == "status":
        print(json.dumps(store.status(), separators=(",", ":"), sort_keys=True))
        return
    if args.command == "queue":
        try:
            command = store.queue_command(args.action)
        except RuntimeError as exc:
            raise SystemExit(str(exc)) from exc
        print(f"COMMAND_QUEUED id={command['id']} action={command['action']}")
        return
    if (
        args.stream_interval <= 0
        or args.stream_chunk_bytes <= 0
        or args.stream_total_bytes <= 0
        or (args.enable_rsd_relay and args.rsd_relay_wait_seconds <= 0)
    ):
        raise SystemExit("stream settings and enabled relay settings must be positive")
    server = AgentHTTPServer(
        (args.bind, args.port),
        store,
        lease_seconds=args.lease_seconds,
        stream_interval=args.stream_interval,
        stream_chunk_bytes=args.stream_chunk_bytes,
        stream_total_bytes=args.stream_total_bytes,
        enable_legacy_transport=args.enable_legacy_transport,
        enable_rsd_relay=args.enable_rsd_relay,
        rsd_relay_host=args.rsd_relay_host,
        rsd_relay_port=args.rsd_relay_port,
        rsd_relay_wait_seconds=args.rsd_relay_wait_seconds,
    )
    relay_status = "disabled"
    if server.rsd_relay is not None:
        relay_status = f"{server.rsd_relay.listen_host}:{server.rsd_relay.listen_port}"
    legacy_status = "enabled" if server.enable_legacy_transport else "disabled"
    print(
        f"JARVIS_AGENT_SERVER_READY bind={args.bind} port={args.port} "
        f"legacy_transport={legacy_status} rsd_relay={relay_status}",
        flush=True,
    )
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
