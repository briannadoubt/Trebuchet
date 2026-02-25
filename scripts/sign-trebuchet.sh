#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS_FILE="${ROOT_DIR}/.github/entitlements/trebuchet.entitlements"

if [[ ! -f "${ENTITLEMENTS_FILE}" ]]; then
  echo "error: entitlements file not found: ${ENTITLEMENTS_FILE}" >&2
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign is required but was not found in PATH" >&2
  exit 1
fi

TARGET_BINARY="${1:-${ROOT_DIR}/.build/debug/trebuchet}"
SIGNING_IDENTITY="${TREBUCHET_CODESIGN_IDENTITY:--}"

if [[ ! -f "${TARGET_BINARY}" ]]; then
  echo "error: binary not found: ${TARGET_BINARY}" >&2
  exit 1
fi

if [[ ! -w "${TARGET_BINARY}" ]]; then
  echo "error: binary is not writable: ${TARGET_BINARY}" >&2
  exit 1
fi

echo "Signing ${TARGET_BINARY} with ${ENTITLEMENTS_FILE}"
codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --entitlements "${ENTITLEMENTS_FILE}" \
  --timestamp=none \
  "${TARGET_BINARY}"

echo "Verifying entitlement signature..."
codesign --verify --strict --verbose=2 "${TARGET_BINARY}"
codesign -d --entitlements :- "${TARGET_BINARY}" >/dev/null

echo "Signed successfully: ${TARGET_BINARY}"
