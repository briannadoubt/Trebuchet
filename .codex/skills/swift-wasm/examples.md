# Swift WASM Examples

## Debug Build

```bash
swift build --swift-sdk swift-6.2.3-RELEASE_wasm
```

## Release Build (Size-Oriented)

```bash
swift build --swift-sdk swift-6.2.3-RELEASE_wasm -c release -Xswiftc -Osize
```

## Full Optimization Build

```bash
swift build \
  --swift-sdk swift-6.2.3-RELEASE_wasm \
  -c release \
  -Xswiftc -Osize \
  -Xswiftc -whole-module-optimization \
  -Xlinker --lto-O3 \
  -Xlinker --gc-sections \
  -Xlinker --strip-debug
```

## Example App Loop

```bash
cd Examples/TodoApp
swift build --swift-sdk swift-6.2.3-RELEASE_wasm
python3 serve.py
```
