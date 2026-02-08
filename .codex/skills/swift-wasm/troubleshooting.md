# Swift WASM Troubleshooting

## "No available targets compatible with wasm32-unknown-wasip1"

Likely causes:
- using Apple/Xcode Swift instead of swift.org toolchain
- missing WASM SDK install

Checks:

```bash
swift --version
swift sdk list
```

## WASM File Is Too Large

Use release optimization flags:

```bash
swift build --swift-sdk swift-6.2.3-RELEASE_wasm -c release -Xswiftc -Osize
```

Then add LTO/strip options from `examples.md`.

## Browser Shows Old Behavior

- confirm served WASM path matches rebuilt artifact
- use versioned WASM names or cache-busting query params
- hard refresh and clear site cache when needed
