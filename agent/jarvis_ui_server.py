#!/usr/bin/env python3
"""Authenticated, opt-in Jarvis full-UI rendezvous for unlocked screens.

This is deliberately separate from the production fixed-command server.  The
Agent polls over Funnel; operators queue requests only from the VPS/local CLI.
Pairing material and passcodes are never accepted. UI bodies are root-only,
bounded, short-lived files and are never written to HTTP logs.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import tempfile
import threading
import time
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8766
DEFAULT_STATE_DIR = Path("/var/lib/jarvis-ui")
DEFAULT_TOKEN_FILE = Path("/var/lib/jarvis-agent/token.json")
MAX_AGENT_RESULT = 12 * 1024 * 1024
MAX_WDA_RESPONSE = 8 * 1024 * 1024
MAX_WDA_REQUEST = 512 * 1024
SAFE_PATH = re.compile(r"^/[A-Za-z0-9._~!$&'()*+,;=:@%/-]{1,511}$")
ALLOWED_METHODS = {"GET", "POST", "DELETE"}
ALLOWED_ERRORS = {"none", "device-locked", "invalid-request", "wda-unreachable", "response-too-large"}


def atomic_json(path: Path, value: dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
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


class UIStore:
    def __init__(self, state_dir: Path, token_file: Path) -> None:
        self.state_dir = state_dir
        self.token_file = token_file
        self.command_file = state_dir / "command.json"
        self.result_file = state_dir / "result.json"
        self.lock_file = state_dir / ".lock"
        state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(state_dir, 0o700)
        self.lock_file.touch(mode=0o600, exist_ok=True)

    def _locked(self):
        descriptor = os.open(self.lock_file, os.O_RDWR | os.O_CLOEXEC)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor

    @staticmethod
    def _unlock(descriptor: int) -> None:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)

    def token_record(self) -> tuple[str, str]:
        record = json.loads(self.token_file.read_text(encoding="ascii"))
        return str(record["device_id"]), str(record["token_sha256"])

    def authenticate(self, token: str, device_id: str) -> bool:
        try:
            bound, expected = self.token_record()
        except (OSError, ValueError, KeyError, TypeError):
            return False
        actual = hashlib.sha256(token.encode("utf-8")).hexdigest()
        return hmac.compare_digest(bound, device_id) and hmac.compare_digest(expected, actual)

    def queue(self, method: str, path: str, body: bytes) -> str:
        if method not in ALLOWED_METHODS or not SAFE_PATH.fullmatch(path):
            raise ValueError("invalid WDA request")
        if len(body) > MAX_WDA_REQUEST:
            raise ValueError("WDA request body too large")
        descriptor = self._locked()
        try:
            if self.command_file.exists():
                raise RuntimeError("a UI request is already pending or ambiguous")
            device_id, _ = self.token_record()
            command_id = secrets.token_hex(16)
            atomic_json(self.command_file, {
                "id": command_id,
                "device_id": device_id,
                "method": method,
                "path": path,
                "body_b64": base64.b64encode(body).decode("ascii"),
                "state": "queued",
                "queued_at": time.time(),
            })
            try:
                self.result_file.unlink()
            except FileNotFoundError:
                pass
            return command_id
        finally:
            self._unlock(descriptor)

    def poll(self, device_id: str) -> dict[str, Any] | None:
        descriptor = self._locked()
        try:
            try:
                command = json.loads(self.command_file.read_text(encoding="ascii"))
            except (OSError, ValueError, TypeError):
                return None
            if command.get("device_id") != device_id or command.get("state") != "queued":
                return None
            command["state"] = "delivered"
            command["delivered_at"] = time.time()
            atomic_json(self.command_file, command)
            return {key: command[key] for key in ("id", "method", "path", "body_b64")}
        finally:
            self._unlock(descriptor)

    def complete(self, device_id: str, payload: dict[str, Any]) -> None:
        command_id = payload.get("id")
        status_code = payload.get("status_code")
        error = payload.get("error")
        encoded = payload.get("body_b64")
        if not isinstance(command_id, str) or not re.fullmatch(r"[0-9a-f]{32}", command_id):
            raise ValueError("invalid UI result id")
        if type(status_code) is not int or not 0 <= status_code <= 599:
            raise ValueError("invalid WDA status")
        if error not in ALLOWED_ERRORS or not isinstance(encoded, str):
            raise ValueError("invalid UI result")
        if len(encoded) > ((MAX_WDA_RESPONSE + 2) // 3) * 4 + 4:
            raise ValueError("encoded UI result too large")
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ValueError("invalid UI result encoding") from exc
        if len(decoded) > MAX_WDA_RESPONSE:
            raise ValueError("UI result too large")
        descriptor = self._locked()
        try:
            command = json.loads(self.command_file.read_text(encoding="ascii"))
            if (command.get("id") != command_id or command.get("device_id") != device_id
                    or command.get("state") != "delivered"):
                raise PermissionError("UI result does not match delivered request")
            atomic_json(self.result_file, {
                "id": command_id,
                "status_code": status_code,
                "error": error,
                "body_b64": encoded,
                "received_at": time.time(),
            })
            self.command_file.unlink()
        finally:
            self._unlock(descriptor)

    def result(self, command_id: str) -> dict[str, Any] | None:
        try:
            result = json.loads(self.result_file.read_text(encoding="ascii"))
        except (OSError, ValueError, TypeError):
            return None
        return result if result.get("id") == command_id else None

    def status(self) -> dict[str, Any]:
        output: dict[str, Any] = {"pending": False, "result": None}
        try:
            command = json.loads(self.command_file.read_text(encoding="ascii"))
            output["pending"] = True
            output["command"] = {key: command.get(key) for key in ("id", "method", "path", "state", "queued_at", "delivered_at")}
        except (OSError, ValueError, TypeError):
            pass
        try:
            result = json.loads(self.result_file.read_text(encoding="ascii"))
            output["result"] = {key: result.get(key) for key in ("id", "status_code", "error", "received_at")}
        except (OSError, ValueError, TypeError):
            pass
        return output


class UIServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, address, store: UIStore):
        self.store = store
        super().__init__(address, UIHandler)


class UIHandler(BaseHTTPRequestHandler):
    server: UIServer

    def log_message(self, _format: str, *_args: Any) -> None:
        # UI paths and bodies can be sensitive; never emit request logs.
        return

    def _path(self) -> str:
        path = self.path.split("?", 1)[0]
        if path.startswith("/jarvis-ui/"):
            return path[len("/jarvis-ui"):]
        return path

    def _json(self, status: int, value: dict[str, Any]) -> None:
        body = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("ascii")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read(self, maximum: int) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError as exc:
            raise ValueError("invalid content length") from exc
        if not 0 <= length <= maximum:
            raise ValueError("invalid content length")
        body = self.rfile.read(length)
        value = json.loads(body.decode("ascii"))
        if not isinstance(value, dict):
            raise ValueError("body must be object")
        return value

    def _auth(self, body: dict[str, Any]) -> str:
        device_id = body.get("device_id")
        header = self.headers.get("Authorization", "")
        if not isinstance(device_id, str) or not header.startswith("Bearer "):
            raise PermissionError("authentication required")
        if not self.server.store.authenticate(header[7:], device_id):
            raise PermissionError("authentication failed")
        return device_id

    def do_GET(self) -> None:
        if self._path() == "/healthz":
            self._json(HTTPStatus.OK, {"ok": True, "service": "jarvis-full-ui-v1"})
        else:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not-found"})

    def do_POST(self) -> None:
        try:
            path = self._path()
            maximum = MAX_AGENT_RESULT if path == "/v1/result" else 4096
            body = self._read(maximum)
            device_id = self._auth(body)
            if path == "/v1/poll":
                command = self.server.store.poll(device_id)
                self._json(HTTPStatus.OK, {"command": command})
            elif path == "/v1/result":
                self.server.store.complete(device_id, body)
                self._json(HTTPStatus.OK, {"ok": True})
            else:
                self._json(HTTPStatus.NOT_FOUND, {"error": "not-found"})
        except PermissionError:
            self._json(HTTPStatus.FORBIDDEN, {"error": "forbidden"})
        except (ValueError, json.JSONDecodeError, UnicodeError, OSError, KeyError):
            self._json(HTTPStatus.BAD_REQUEST, {"error": "invalid-request"})


def request_command(args: argparse.Namespace, store: UIStore) -> None:
    body = b""
    if args.body_file:
        body = Path(args.body_file).read_bytes()
    command_id = store.queue(args.method, args.path, body)
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        result = store.result(command_id)
        if result is not None:
            decoded = base64.b64decode(result["body_b64"], validate=True)
            if args.output:
                output = Path(args.output)
                fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC, 0o600)
                with os.fdopen(fd, "wb") as stream:
                    stream.write(decoded)
                os.chmod(output, 0o600)
            else:
                os.write(sys.stdout.fileno(), decoded)
            print(f"\nUI_REQUEST_COMPLETE id={command_id} status={result['status_code']} error={result['error']} bytes={len(decoded)}", file=sys.stderr)
            return
        time.sleep(0.2)
    raise TimeoutError(f"UI request ambiguous or timed out: {command_id}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE)
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--bind", default=DEFAULT_BIND)
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    request = sub.add_parser("request")
    request.add_argument("--method", choices=sorted(ALLOWED_METHODS), required=True)
    request.add_argument("--path", required=True)
    request.add_argument("--body-file")
    request.add_argument("--output")
    request.add_argument("--timeout", type=float, default=30.0)
    sub.add_parser("status")
    args = parser.parse_args()
    store = UIStore(args.state_dir, args.token_file)
    if args.command == "serve":
        server = UIServer((args.bind, args.port), store)
        print(f"JARVIS_UI_SERVER_READY bind={args.bind} port={args.port}", flush=True)
        server.serve_forever()
    elif args.command == "request":
        request_command(args, store)
    else:
        print(json.dumps(store.status(), separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
