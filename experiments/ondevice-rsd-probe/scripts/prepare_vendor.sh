#!/usr/bin/env bash
# Fetch and patch the exact idevice source used by the experimental probe.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/idevice"
PATCH="$ROOT/patches/idevice-verify-only-privacy-and-bounds.patch"
REPOSITORY='https://github.com/jkcoxson/idevice.git'
COMMIT='63a341d7f624b5c1f2540e4cecb269151a2caf52'
TREE='ac08b6133eb024eb1a4f06cf25fdd598a79daa72'
PATCH_SHA256='ad5ce44440618e948f0eb403a21fe9146aba156a76269dd0e3e438639e4b78fc'
MARKER="$VENDOR/.jarvis-patched"

if [[ "${1:-}" == '--refresh' ]]; then
  rm -rf "$VENDOR"
elif [[ -f "$MARKER" ]] \
  && grep -qx "commit=$COMMIT" "$MARKER" \
  && grep -qx "tree=$TREE" "$MARKER" \
  && grep -qx "patch_sha256=$PATCH_SHA256" "$MARKER"; then
  echo "JARVIS_VENDOR_READY commit=$COMMIT"
  exit 0
elif [[ -e "$VENDOR" ]]; then
  echo 'refusing unexpected or partially prepared vendor directory; use --refresh' >&2
  exit 2
fi

[[ "$(sha256sum "$PATCH" | awk '{print $1}')" == "$PATCH_SHA256" ]] \
  || { echo 'dependency patch hash mismatch' >&2; exit 3; }
mkdir -p "$(dirname "$VENDOR")"
GIT_TERMINAL_PROMPT=0 git clone --quiet --no-tags "$REPOSITORY" "$VENDOR"
git -C "$VENDOR" checkout --quiet --detach "$COMMIT"
[[ "$(git -C "$VENDOR" rev-parse HEAD)" == "$COMMIT" ]] \
  || { echo 'dependency commit mismatch' >&2; exit 3; }
[[ "$(git -C "$VENDOR" rev-parse 'HEAD^{tree}')" == "$TREE" ]] \
  || { echo 'dependency tree mismatch' >&2; exit 3; }

# The source tree hash is verified above, so a zero-context patch is both
# deterministic and avoids committing nested-diff whitespace artifacts.
git -C "$VENDOR" apply --unidiff-zero --check "$PATCH"
git -C "$VENDOR" apply --unidiff-zero "$PATCH"
git -C "$VENDOR" diff --check
changed="$(
  {
    git -C "$VENDOR" diff --name-only
    git -C "$VENDOR" ls-files --others --exclude-standard
  } | sort
)"
expected="$(printf '%s\n' \
  'idevice/Cargo.toml' \
  'idevice/src/remote_pairing/mod.rs' \
  'idevice/src/remote_pairing/rp_pairing_file.rs' \
  'idevice/src/remote_pairing/tlv.rs' \
  'idevice/src/remote_pairing/tunnel.rs' \
  'idevice/src/lib.rs' \
  'idevice/src/services/mod.rs' \
  'idevice/src/services/dvt/mod.rs' \
  'idevice/src/services/dvt/fixed_channel_probe.rs' \
  'idevice/src/services/dvt/xctest/mod.rs' \
  | sort)"
[[ "$changed" == "$expected" ]] \
  || { printf 'unexpected patched files:\n%s\n' "$changed" >&2; exit 3; }

cat > "$MARKER" <<EOF
commit=$COMMIT
tree=$TREE
patch_sha256=$PATCH_SHA256
EOF
chmod 600 "$MARKER"
echo "JARVIS_VENDOR_READY commit=$COMMIT tree=$TREE"
