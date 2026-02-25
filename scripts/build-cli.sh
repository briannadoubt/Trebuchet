#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"

if [[ "${CONFIG}" != "debug" && "${CONFIG}" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 1
fi

cd "${ROOT_DIR}"

BUILD_ARGS=(--product trebuchet)
if [[ "${CONFIG}" == "release" ]]; then
  BUILD_ARGS+=(--configuration release)
fi

echo "Building trebuchet (${CONFIG})..."
swift build "${BUILD_ARGS[@]}"

BINARY_PATH="${ROOT_DIR}/.build/${CONFIG}/trebuchet"
echo "Signing trebuchet binary..."
"${ROOT_DIR}/scripts/sign-trebuchet.sh" "${BINARY_PATH}"

echo "Build + sign complete: ${BINARY_PATH}"
