#!/bin/sh
# Compile the actual package engine to Wasm locally. No hosted CI is involved.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SWIFT_BIN=${SWIFT_WASM_SWIFT:-swift}
SDK=${SWIFT_WASM_SDK:-swift-6.4.1-RELEASE_wasm}

if ! "$SWIFT_BIN" sdk list | grep -Fx "$SDK" >/dev/null; then
    echo "Missing Swift WebAssembly SDK: $SDK" >&2
    echo "Use a matching official Swift toolchain and SDK; see Examples/Web/README.md." >&2
    exit 1
fi

"$SWIFT_BIN" build --package-path "$ROOT/Examples/Web" --swift-sdk "$SDK" \
    --configuration release --product ForceGraphWasm -Xswiftc -Osize -Xlinker --strip-all
BIN_PATH=$("$SWIFT_BIN" build --package-path "$ROOT/Examples/Web" --swift-sdk "$SDK" \
    --configuration release --show-bin-path)
cp "$BIN_PATH/ForceGraphWasm.wasm" "$ROOT/Web/forcegraph.wasm"
gzip -n -9 -c "$ROOT/Web/forcegraph.wasm" > "$ROOT/Web/forcegraph.wasm.gz"

python3 - "$ROOT" "$SDK" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
wasm = root / 'Web/forcegraph.wasm'
info = {
    'sourceCommit': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
    'sourceDirty': bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], text=True).strip()),
    'swiftSDK': sys.argv[2],
    'sha256': hashlib.sha256(wasm.read_bytes()).hexdigest(),
    'wasmBytes': wasm.stat().st_size,
    'downloadBytes': (root / 'Web/forcegraph.wasm.gz').stat().st_size,
}
(root / 'Web/build-info.json').write_text(json.dumps(info, indent=2) + '\n')
print(json.dumps(info, indent=2))
PY
FORCEGRAPH_WASM="$ROOT/Web/forcegraph.wasm" node --test "$ROOT"/Tests/Web/*.test.mjs
