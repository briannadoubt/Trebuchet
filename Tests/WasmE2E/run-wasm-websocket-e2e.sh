#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SWIFT_SDK="swift-6.2.3-RELEASE_wasm"
SWIFTLY_BIN="/opt/homebrew/bin/swiftly"
NODE22_BIN="/opt/homebrew/opt/node@22/bin"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

if command -v "${SWIFTLY_BIN}" >/dev/null 2>&1; then
  SWIFT_BUILD_CMD=("${SWIFTLY_BIN}" run swift build)
else
  SWIFT_BUILD_CMD=(swift build)
fi

WORK_DIR="$(mktemp -d /tmp/trebuchet-wasm-e2e.XXXXXX)"
cleanup() {
  if [[ -n "${ECHO_SERVER_PID:-}" ]]; then
    kill "${ECHO_SERVER_PID}" >/dev/null 2>&1 || true
    wait "${ECHO_SERVER_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

cat > "${WORK_DIR}/Package.swift" <<SWIFT
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WasmTransportProbe",
    platforms: [.custom("wasi", versionString: "1.0")],
    products: [
        .executable(name: "WasmTransportProbe", targets: ["WasmTransportProbe"]),
    ],
    dependencies: [
        .package(path: "${REPO_ROOT}"),
    ],
    targets: [
        .executableTarget(
            name: "WasmTransportProbe",
            dependencies: [
                .product(name: "Trebuchet", package: "Trebuchet"),
            ]
        )
    ]
)
SWIFT

mkdir -p "${WORK_DIR}/Sources/WasmTransportProbe"
cat > "${WORK_DIR}/Sources/WasmTransportProbe/main.swift" <<'SWIFT'
import Foundation
import Trebuchet
import JavaScriptKit
import JavaScriptEventLoop

@_expose(wasm, "runProbe")
public func runProbe() {
    JavaScriptEventLoop.installGlobalExecutor()
    JSObject.global.probeResult = .string("RUNNING")

    Task {
        let endpoint = Endpoint(host: "127.0.0.1", port: 8765)
        let transport = WebSocketTransport()
        let payload = Data("trebuchet-wasm-e2e".utf8)

        do {
            try await transport.connect(to: endpoint)
            try await transport.send(payload, to: endpoint)

            var iterator = transport.incoming.makeAsyncIterator()
            guard let message = await iterator.next() else {
                JSObject.global.probeResult = .string("FAIL:no-message")
                await transport.shutdown()
                return
            }

            JSObject.global.probeResult = .string(message.data == payload ? "PASS" : "FAIL:mismatch")
            await transport.shutdown()
        } catch {
            JSObject.global.probeResult = .string("FAIL:error")
            await transport.shutdown()
        }
    }
}
SWIFT

echo "[1/5] Building WASM probe"
"${SWIFT_BUILD_CMD[@]}" \
  --swift-sdk "${SWIFT_SDK}" \
  --package-path "${WORK_DIR}" \
  -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor >/dev/null

WASM_PATH="${WORK_DIR}/.build/wasm32-unknown-wasip1/debug/WasmTransportProbe.wasm"
RUNTIME_PATH="${WORK_DIR}/.build/wasm32-unknown-wasip1/debug/JavaScriptKit_JavaScriptKit.resources/Runtime/index.mjs"

if [[ ! -f "${WASM_PATH}" || ! -f "${RUNTIME_PATH}" ]]; then
  echo "error: expected wasm build artifacts not found" >&2
  exit 1
fi

echo "[2/5] Starting local echo server"
python3 -m venv "${WORK_DIR}/.venv"
source "${WORK_DIR}/.venv/bin/activate"
pip install --quiet websockets
cat > "${WORK_DIR}/echo_server.py" <<'PY'
import asyncio
import websockets

async def echo(ws):
    async for message in ws:
        await ws.send(message)

async def main():
    async with websockets.serve(echo, "127.0.0.1", 8765):
        await asyncio.Future()

asyncio.run(main())
PY
python "${WORK_DIR}/echo_server.py" >/dev/null 2>&1 &
ECHO_SERVER_PID=$!
sleep 1

echo "[3/5] Preparing node WASI runner"
mkdir -p "${WORK_DIR}/node-run"
cp "${WASM_PATH}" "${WORK_DIR}/node-run/WasmTransportProbe.wasm"
cp "${RUNTIME_PATH}" "${WORK_DIR}/node-run/swift-runtime.mjs"
cat > "${WORK_DIR}/node-run/package.json" <<'JSON'
{
  "name": "trebuchet-wasm-e2e-runner",
  "private": true,
  "type": "module",
  "dependencies": {
    "@wasmer/wasi": "0.12.0",
    "@wasmer/wasmfs": "0.12.0"
  }
}
JSON
cat > "${WORK_DIR}/node-run/run.mjs" <<'JS'
import fs from "node:fs/promises";
import { SwiftRuntime } from "./swift-runtime.mjs";
import { WASI } from "@wasmer/wasi";
import { WasmFs } from "@wasmer/wasmfs";

const swift = new SwiftRuntime();
const wasmFs = new WasmFs();

const wasi = new WASI({
  args: [],
  env: {},
  bindings: {
    ...WASI.defaultBindings,
    fs: wasmFs.fs,
  },
});

const wasmBytes = await fs.readFile("./WasmTransportProbe.wasm");
const { instance } = await WebAssembly.instantiate(wasmBytes, {
  wasi_snapshot_preview1: wasi.wasiImport,
  javascript_kit: swift.wasmImports,
});

swift.setInstance(instance);
wasi.setMemory(instance.exports.memory);
instance.exports._initialize();
instance.exports.runProbe();

const timeoutMs = 7000;
const start = Date.now();
while (Date.now() - start < timeoutMs) {
  if (globalThis.probeResult === "PASS") {
    console.log("PROBE_RESULT=PASS");
    process.exit(0);
  }
  if (typeof globalThis.probeResult === "string" && globalThis.probeResult.startsWith("FAIL")) {
    console.error(`PROBE_RESULT=${globalThis.probeResult}`);
    process.exit(1);
  }
  await new Promise((resolve) => setTimeout(resolve, 100));
}

console.error(`PROBE_RESULT_TIMEOUT=${globalThis.probeResult ?? "<nil>"}`);
process.exit(1);
JS

if [[ -x "${NODE22_BIN}/node" ]]; then
  export PATH="${NODE22_BIN}:${PATH}"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found (install node or node@22)" >&2
  exit 1
fi

echo "[4/5] Running node WASI probe"
(
  cd "${WORK_DIR}/node-run"
  npm install --silent
  node run.mjs
)

echo "[5/5] WASM websocket e2e passed"
