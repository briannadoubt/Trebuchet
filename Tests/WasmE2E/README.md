# WASM WebSocket E2E

This folder contains a real end-to-end runtime check for Trebuchet's WASI WebSocket transport.

## What it verifies

- Trebuchet builds for `wasm32-unknown-wasip1`
- A WASM probe can connect to a live WebSocket server
- The probe sends a payload and receives the echoed payload back

## Run

```bash
./Tests/WasmE2E/run-wasm-websocket-e2e.sh
```

Expected success signal:

```text
PROBE_RESULT=PASS
```
