# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0, minor
versions may contain breaking changes.

## [Unreleased]

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

[Unreleased]: https://github.com/ianleon/ForceGraph/compare/0.1.0...HEAD
[0.1.0]: https://github.com/ianleon/ForceGraph/releases/tag/0.1.0
