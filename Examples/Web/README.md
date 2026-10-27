# ForceGraph in the browser

The demo compiles the package's real `ForceSimulation` to WebAssembly. JavaScript draws
positions on an HTML Canvas and handles browser gestures; it does not simulate physics.
SwiftUI's `ForceGraphView` is available on Apple platforms and does not run in a browser.

## Build locally

Use the matching official Swift 6.4.1 toolchain and WebAssembly SDK. Xcode's toolchain alone
is insufficient. Follow [Swift's installation guide](https://www.swift.org/documentation/articles/wasm-getting-started.html).
The checked release SDK is:

```sh
swift sdk install https://download.swift.org/swift-6.4.1-release/wasm-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_wasm.artifactbundle.tar.gz \
    --checksum 783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8
Scripts/build-web-demo.sh
python3 -m http.server 8766 --directory Web
```

Set `SWIFT_WASM_SWIFT` to an alternate compiler executable and `SWIFT_WASM_SDK` to its matching
SDK identifier when necessary. The build script compiles, strips symbols, gzip-compresses the
module, writes a source/hash manifest, and runs the Node test suite. Generated binaries stay
out of the source branch. Serve through HTTP, because browsers cannot fetch Wasm from file URLs.

The full Swift and Foundation runtime makes the initial download substantial (about 20 MB
gzipped with the pinned SDK). The browser caches the static assets. A loading bar reports downloaded bytes and then
shows compilation and startup as separate indeterminate stages. No private vault data,
external fonts, analytics, remote simulation service, or third-party JavaScript is involved.

## Browser bridge

`Sources/ForceGraphWasm/main.swift` exports a small numeric ABI. It owns one graph per Wasm
instance and supports at most 1,000 nodes and 10,000 edges. Calls are synchronous on a single
browser event loop. A minimal WASI Preview1 host supplies clocks, empty arguments, randomness
and stdout/stderr, with no filesystem access. Errors or missing exports are surfaced instead
of falling back to JavaScript physics. Modern browsers need WebAssembly and DecompressionStream.

The tests exercise the host, ABI validation, simulation updates, exact drag coordinates,
settling and comparison with a native Swift reference fixture (rounded to wasm32’s
32-bit `CGFloat` precision). They do not establish that the
SwiftUI view is portable to the web.

## Publish to GitHub Pages

After reviewing a local build, run `Scripts/publish-web-demo.sh`. It pushes only the built
assets to `ianleon/ForceGraph`'s `gh-pages` branch. Configure Pages to deploy from that branch's
root. `.nojekyll` bypasses Jekyll; no repository Actions workflow or hosted CI is added.
The script never force-pushes and does not change the source checkout. The build manifest
records the source commit, SDK, raw-module SHA-256 and asset sizes.
