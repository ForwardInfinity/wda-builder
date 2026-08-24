#!/usr/bin/env bash
# Install the signed foreground probe and stage exactly one validated pairing file.
# This script never launches the app, starts RSD, or performs a UI/secret action.
set -euo pipefail
set +x
umask 077

UDID='00008101-00064D1A3A68001E'
BUNDLE='com.forwardinfinity.jarvisrsdprobe'
EXPECTED_IPA_SHA256='d1f1453ef607f99cfeabb1f47e04f5bb19005d0a049c479384126029c113daf4'
EXPECTED_PAIRING_SHA256='6e210a0515f1af27e4d8ce72b11061886c069415c153a617b5a9f19cc7a57e78'
PROJECT='/home/huy-nguyen/workspace/iphone-tailnet-control'
IPA="$PROJECT/artifacts/jarvis-rsd-probe-verify-only-v1-signed.ipa"
PAIRING="$HOME/.local/share/jarvis-rsd-probe/bootstrap.mobiledevicepairing"
PMD="$HOME/.local/share/pipx/venvs/pymobiledevice3/bin/pymobiledevice3"
LOCK='/run/user/1000/jarvis-rsd-probe-bootstrap.lock'
TMP="$(mktemp -d /tmp/jarvis-rsd-bootstrap.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

exec 9>"$LOCK"
flock -n 9 || { echo 'BOOTSTRAP_BLOCKED another bootstrap is active' >&2; exit 2; }
[[ -x "$PMD" ]] || { echo 'BOOTSTRAP_BLOCKED pymobiledevice3 unavailable' >&2; exit 2; }
[[ -f "$IPA" && "$(stat -c %a "$IPA")" == 600 ]] \
  || { echo 'BOOTSTRAP_BLOCKED signed probe missing or wrong mode' >&2; exit 2; }
[[ -f "$PAIRING" && "$(stat -c %a "$PAIRING")" == 600 ]] \
  || { echo 'BOOTSTRAP_BLOCKED pairing staging source missing or wrong mode' >&2; exit 2; }
[[ "$(sha256sum "$IPA" | awk '{print $1}')" == "$EXPECTED_IPA_SHA256" ]] \
  || { echo 'BOOTSTRAP_BLOCKED signed probe hash mismatch' >&2; exit 2; }
[[ "$(sha256sum "$PAIRING" | awk '{print $1}')" == "$EXPECTED_PAIRING_SHA256" ]] \
  || { echo 'BOOTSTRAP_BLOCKED pairing staging hash mismatch' >&2; exit 2; }

python3 - "$IPA" "$PAIRING" <<'PY'
import datetime as dt
import os
import plistlib
import subprocess
import sys
import zipfile
ipa, pairing = sys.argv[1:]
with zipfile.ZipFile(ipa) as z:
    infos = [n for n in z.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
    profiles = [n for n in z.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/embedded.mobileprovision')]
    if len(infos) != 1 or len(profiles) != 1:
        raise SystemExit('BOOTSTRAP_BLOCKED invalid signed IPA structure')
    info = plistlib.loads(z.read(infos[0]))
    profile_der = z.read(profiles[0])
if info.get('CFBundleIdentifier') != 'com.forwardinfinity.jarvisrsdprobe' or info.get('UIDeviceFamily') != [1]:
    raise SystemExit('BOOTSTRAP_BLOCKED signed IPA scope mismatch')
if 'UIBackgroundModes' in info:
    raise SystemExit('BOOTSTRAP_BLOCKED background mode present')
profile_path = os.path.join(os.path.dirname(pairing), '.profile-check.tmp')
try:
    with open(profile_path, 'wb') as f:
        f.write(profile_der)
    os.chmod(profile_path, 0o600)
    xml = subprocess.check_output(
        ['openssl', 'smime', '-inform', 'der', '-verify', '-noverify', '-in', profile_path],
        stderr=subprocess.DEVNULL,
    )
finally:
    try: os.unlink(profile_path)
    except FileNotFoundError: pass
profile = plistlib.loads(xml)
entitlements = profile.get('Entitlements', {})
if not str(entitlements.get('application-identifier', '')).endswith('.com.forwardinfinity.jarvisrsdprobe'):
    raise SystemExit('BOOTSTRAP_BLOCKED profile scope mismatch')
expiration = profile.get('ExpirationDate')
if expiration is None:
    raise SystemExit('BOOTSTRAP_BLOCKED profile expiration missing')
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=dt.timezone.utc)
if expiration <= dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=6):
    raise SystemExit('BOOTSTRAP_BLOCKED profile expires too soon')
record = plistlib.load(open(pairing, 'rb'))
if set(record) != {'identifier', 'private_key', 'public_key'}:
    raise SystemExit('BOOTSTRAP_BLOCKED pairing schema mismatch')
if len(record['identifier']) != 36 or len(record['private_key']) != 32 or len(record['public_key']) != 32:
    raise SystemExit('BOOTSTRAP_BLOCKED pairing field length mismatch')
print('BOOTSTRAP_STATIC_INPUT_PASS')
PY

timeout 15 "$PMD" usbmux list --usb --simple \
  >"$TMP/usbmux.json" 2>"$TMP/usbmux.err" \
  || { echo 'BOOTSTRAP_WAITING connect exactly the approved iPhone over USB' >&2; exit 3; }
python3 - "$TMP/usbmux.json" <<'PY'
import json,sys
devices=json.load(open(sys.argv[1],encoding='utf-8'))
if devices != ['00008101-00064D1A3A68001E']:
    raise SystemExit('BOOTSTRAP_WAITING connect exactly the approved iPhone over USB')
PY
echo 'BOOTSTRAP_USB_SCOPE_PASS'

# A bounded lockdown query confirms trust/connectivity without printing device metadata.
timeout 20 "$PMD" lockdown info --udid "$UDID" >"$TMP/lockdown.json" 2>"$TMP/lockdown.err" \
  || { echo 'BOOTSTRAP_WAITING unlock and trust the iPhone directly' >&2; exit 3; }
python3 - "$TMP/lockdown.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8'))
if p.get('UniqueDeviceID') != '00008101-00064D1A3A68001E':
    raise SystemExit('BOOTSTRAP_BLOCKED lockdown identity mismatch')
print('BOOTSTRAP_LOCKDOWN_PASS os=' + str(p.get('ProductVersion', 'unknown')))
PY

# Installation and staging outputs are kept in mode-0600 temporary files and
# reduced to fixed status lines.
timeout 180 "$PMD" apps install --udid "$UDID" "$IPA" \
  >"$TMP/install.out" 2>"$TMP/install.err" \
  || { echo 'BOOTSTRAP_INSTALL_FAILED no pairing file was staged' >&2; exit 4; }
timeout 30 "$PMD" apps query --udid "$UDID" "$BUNDLE" \
  >"$TMP/query.json" 2>"$TMP/query.err" \
  || { echo 'BOOTSTRAP_VERIFY_FAILED no pairing file was staged' >&2; exit 4; }
python3 - "$TMP/query.json" <<'PY'
import json,sys
apps=json.load(open(sys.argv[1],encoding='utf-8'))
if 'com.forwardinfinity.jarvisrsdprobe' not in apps:
    raise SystemExit('BOOTSTRAP_VERIFY_FAILED no pairing file was staged')
PY
echo 'BOOTSTRAP_PROBE_INSTALL_PASS'

timeout 60 "$PMD" apps push --udid "$UDID" \
  "$BUNDLE" "$PAIRING" 'Documents/bootstrap.mobiledevicepairing' \
  >"$TMP/push.out" 2>"$TMP/push.err" \
  || { echo 'BOOTSTRAP_PAIRING_STAGE_FAILED' >&2; exit 5; }
echo 'BOOTSTRAP_PAIRING_STAGED_PASS'
echo 'NEXT_ON_DEVICE: open Jarvis RSD Probe and tap Import fixed USB-staged record'
