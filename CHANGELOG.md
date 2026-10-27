# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0, minor
versions may contain breaking changes.

## [Unreleased]

### Added
- Browser loading progress with streamed download bytes and separate compilation/startup states.
- A GitHub Pages playground running the real Swift simulation in WebAssembly with HTML
  Canvas rendering, dragging, pan/zoom, force sliders and synthetic graph presets.
- Local Wasm build/publish scripts, a minimal browser WASI host and cross-runtime tests
  comparing coordinates with native Swift. Verified using the official Swift 6.4.1 SDK.
- Browser demo ABI limits: 1,000 nodes and 10,000 edges. These do not limit native callers.

## [0.3.0] - 2026-10-26

### Added
- `.simulation(...)` on `ForceGraphView` opts into the live engine. Drag nodes to move
  them while neighbours react, release to settle, and drag empty space to pan. Existing
  fixed-layout callers keep their behavior. Preserves the pointer's grab offset.
- Live interaction respects Reduce Motion, cancels on disappearance and sleeps when settled.
- Focused controller tests and simulation regression coverage for invalid inputs, update
  semantics, final pointer positions and collision configuration.
- `ForceSimulation`, a live force simulation ported from d3-force, next to `ForceLayout`:
  alpha, `alphaMin`, `alphaDecay`, `alphaTarget` and `velocityDecay` with d3's defaults;
  `tick(_:)`, `step()` (ticks while warm and reports whether it is still running),
  `settle(maximumTicks:)` for Reduce Motion, and `reheat(to:)`. Deterministic for a seed,
  `Sendable`, and usable off the main actor; a tick allocates nothing once it has run.
- Forces, configured with `ForceSimulationConfiguration`: link springs with d3's
  degree-based default strength and bias (`LinkForce`), Barnes–Hut many-body repulsion
  with `theta`, `distanceMin` and `distanceMax` (`ManyBodyForce`), a pull toward a point
  (`PositionForce`, d3's `forceX`/`forceY`), collision with radii that grow with degree
  (`CollisionForce`), and optional re-centering (`CenterForce`).
- Dragging: `beginDrag(_:at:)`, `drag(_:to:)` and `endDrag(_:)` hold a node at the
  pointer and keep the graph warm (`dragAlphaTarget`, 0.3), then let it go unpinned;
  several nodes can be held at once. `fix(_:at:)`, `release(_:)`, `fixedPosition(of:)` and
  `setPosition(_:for:)` for fixed positions (d3's `fx`/`fy`).
- Changing the graph while it runs: `update(nodes:edges:reheatingTo:)`, `add(_:at:)`,
  `remove(_:)`, `add(_ edge:)` and `remove(_ edge:)` keep every remaining node's position,
  velocity and fixed position, start new nodes beside their neighbours, and reheat.
- Directed edges for arrows: `ForceSimulation.edges` keeps each edge's direction and every
  `ForceSimulation.Link` says whether it runs forward, backward or both.
- Reading the state: `nodes`, `links`, `position(at:)`, `position(of:)`, `positions()`,
  `snapshot()`, `velocity(of:)`, `radius(at:)`, `setRadius(_:for:)`, `degree(at:)`,
  `bounds`, `kineticEnergy`, and hit testing with `node(at:slop:)` and
  `nearestNode(to:within:)`.
- `ObsidianGraphForces`: the center, repel, link force and link distance sliders of
  Obsidian's graph view, with their ranges and defaults, decoded from and encoded to the
  keys of `.obsidian/graph.json`, and mapped to a `ForceSimulationConfiguration`.
- The "Live simulation" DocC article, with the slider mapping and measured tick times
  (about 1 ms at 1,000 nodes and 7 ms at 5,000 on an M1 Max, 1.3 ms and 8.4 ms on the
  iPhone 18 Pro simulator, release build).
- `NOTICE`, crediting d3-force and d3-quadtree (ISC License), which the simulation ports.
- Release-mode performance tests at 1,000 and 5,000 nodes, run by `Scripts/check.sh`.

## [0.2.0] - 2026-10-18

### Changed (breaking)
- `ForceGraphView` customizes nodes with modifiers instead of initializer closures:
  `.nodeLabel { … }`, `.nodeColor { … }` and `.nodeRadius { … }` replace the `label:`,
  `nodeColor:` and `radius:` parameters. The initializer's only closure is now `onTap`,
  so the natural `ForceGraphView(nodes:edges:) { tapped in … }` binds the trailing
  closure to the tap handler (in Swift 6 mode it used to bind to `radius:` and fail
  to compile). Each modifier's closure returns an optional; `nil` keeps the default,
  so `.nodeColor { $0 == selected ? .orange : nil }` highlights one node.
  Migrate `ForceGraphView(nodes: n, edges: e, label: { $0.title }) { … }` to
  `ForceGraphView(nodes: n, edges: e) { … }.nodeLabel { $0.title }`.
- `ForceGraphStyle.labelSpacing` is renamed `minimumLabelSpacing`.

### Added
- Warm start: `ForceLayout.initialPositions` starts known nodes where they were and new
  nodes next to their neighbours, at `ForceLayoutConfiguration.warmStartTemperature`
  (default 10), cooling to a stop. `ForceGraphView` uses it when `nodes` or `edges`
  change, so adding a node no longer re-scrambles the whole graph and the user's pan
  and zoom are kept.
- `ForceLayout.Simulation` and `ForceLayout.makeSimulation()` to step a layout from
  your own loop (`step()`, `isFinished`, `completedSteps`, `totalSteps`, `snapshot()`).
- `ForceLayout` is `Hashable`; `ForceGraphStyle` is `Hashable`.
- Memberwise initializers with defaults for `ForceLayoutConfiguration` and
  `ForceGraphStyle`, e.g. `ForceLayoutConfiguration(area: 640_000)`.
- `ForceLayout.degrees` and `ForceLayout.uniqueEdges` instance properties.
- `GraphEdge` is `Codable` when its ID is, and `CustomStringConvertible`.
- `run(reportingEvery:progress:)` defaults to reporting every 8 steps, like `stream()`.
- A "Fit to view" accessibility action on `ForceGraphView`.
- tvOS 16 and watchOS 9 in the manifest's platforms, for the layout (the view remains
  iOS, macOS and visionOS only). Without them SwiftPM assumed tvOS 12 / watchOS 4, where
  the layout does not compile.
- DocC landing page and doc comments for every public symbol.
- `Scripts/check.sh`, the local build and test matrix.

### Fixed
- `ForceGraphView` drew a pair linked in both directions twice, so mutual links looked
  heavier than one-way links; it now draws the de-duplicated edges the layout simulates.
- README: the usage sample imports SwiftUI, the layout-only sample compiles on its own,
  install instructions come first and point at `ianleon/ForceGraph`.

## [0.1.0] - 2026-10-18

### Added
- `ForceLayout`: deterministic Fruchterman–Reingold layout with `run()`,
  `run(reportingEvery:progress:)`, `stream(reportingEvery:minimumInterval:)` and
  `degrees(nodes:edges:)`.
- `ForceLayoutConfiguration` and `GraphEdge`.
- `ForceGraphView`: SwiftUI `Canvas` view with pan, zoom, fit-to-view, tap handling and
  accessibility children, for iOS 17, macOS 14 and visionOS 1.
- `ForceGraphStyle`.

[Unreleased]: https://github.com/ianleon/ForceGraph/compare/0.3.0...HEAD
[0.3.0]: https://github.com/ianleon/ForceGraph/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/ianleon/ForceGraph/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ianleon/ForceGraph/releases/tag/0.1.0
