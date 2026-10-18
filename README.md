# ForceGraph

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fianleon%2FForceGraph%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ianleon/ForceGraph)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fianleon%2FForceGraph%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ianleon/ForceGraph)

A small, dependency-free force-directed graph for Swift: a deterministic
Fruchterman–Reingold layout you can run anywhere, and a SwiftUI `Canvas` view
that animates the layout settling, with pan, zoom, fit-to-view and tap handling.

Extracted from Basalt, where it draws the note graph.

- iOS 17 / macOS 14 / visionOS 1, Swift 6 language mode
- `ForceLayout` has no UI dependency — drive a `Canvas`, an AppKit view, or a test with it.
  `ForceGraphView` is compiled only for iOS, macOS and visionOS; the layout builds everywhere.
- O(n²) per step; comfortable up to ~1,500 nodes

## Use

```swift
import ForceGraph

struct NotesGraph: View {
    let titles: [String]
    let links: [GraphEdge<String>]
    @State private var selected: String?

    var body: some View {
        ForceGraphView(
            nodes: titles,
            edges: links,
            nodeColor: { $0 == selected ? .orange : .accentColor },
            label: { $0 }
        ) { tapped in
            selected = tapped
        }
    }
}
```

Node size defaults to a function of degree; pass `radius:` to override, and
`nodeColor:` to colour nodes individually (a selection, a category). Pass a
`ForceGraphStyle` for colours, label font, zoom limits and fit padding, and a
`ForceLayoutConfiguration` for the simulation (iterations, spacing, gravity, seed).

The view fits the graph to its bounds while it animates and whenever the view
resizes, until the user pans or zooms. Double-tap fits it again, or change the
`fitTrigger:` value to fit from a toolbar button or shortcut. Zoom limits
(`minimumZoom`, `maximumZoom`) are multiples of the fitted scale, and labels
appear once nodes are far enough apart on screen (`labelSpacing`).

Pass `nodes` in a stable order: node order seeds the layout, so an array built
from a `Set` would give a different picture on every launch.

### Layout only

```swift
let layout = ForceLayout(nodes: ids, edges: edges)
let positions: [ID: CGPoint] = layout.run()            // synchronous, settled

for await snapshot in layout.stream() {                 // animated: a snapshot every 8 steps,
    render(snapshot)                                    // at most one per 25 ms
}
```

Positions are centered on the origin in layout units; scale them to your view.
The same nodes, edges, configuration and seed always produce the same layout.

`run()` is synchronous and O(n² × iterations) — about a second for 1,500 nodes
on a Mac in a release build, longer on a phone and much longer in debug builds —
so call it off the main thread for large graphs, or use `stream()`, which runs
on a background task and paces its snapshots (`minimumInterval:`, `.zero` to
disable) so the settling is visible even for small graphs.

## Add to a project

In Xcode: *File → Add Package Dependencies…* and enter
`https://github.com/ianleon/ForceGraph`, or in `Package.swift`:

```swift
.package(url: "https://github.com/ianleon/ForceGraph.git", from: "0.1.0")
```

For local development, add the folder with *Add Local…* or `.package(path: "../ForceGraph")`.

## Test

```sh
swift test
```

## License

MIT. See [LICENSE](LICENSE).
