# ``ForceGraph``

A deterministic force-directed graph layout and a SwiftUI `Canvas` view that draws it.

## Overview

ForceGraph has two parts. ``ForceLayout`` runs a Fruchterman–Reingold simulation over
a list of node identifiers and ``GraphEdge`` values and returns a position for every node.
It has no UI dependency, and the same nodes, edges, configuration and seed always produce
the same layout. ``ForceGraphView`` draws that layout with SwiftUI `Canvas`, animating it
as it settles, with pan, zoom, fit-to-view and tap handling.

The view is available on iOS 17, macOS 14 and visionOS 1; the layout also builds for
tvOS 16 and watchOS 9. Layout cost is O(n²) per step, comfortable up to roughly 1,500 nodes.

## Getting started

Give the view your node identifiers and edges; it lays them out and draws them. The
trailing closure is called with the node the user taps:

```swift
import SwiftUI
import ForceGraph

struct NotesGraph: View {
    let titles: [String]
    let links: [GraphEdge<String>]
    @State private var selected: String?

    var body: some View {
        ForceGraphView(nodes: titles, edges: links) { tapped in
            selected = tapped
        }
        .nodeLabel { $0 }
        .nodeColor { $0 == selected ? .orange : nil }
    }
}
```

Edges are undirected: `GraphEdge(a, b)` links two node identifiers, and duplicate or
reversed pairs count once. Customize individual nodes with
``ForceGraphView/nodeLabel(_:)``, ``ForceGraphView/nodeColor(_:)`` and
``ForceGraphView/nodeRadius(_:)``, the simulation with ``ForceLayoutConfiguration``, and
the view's appearance with ``ForceGraphStyle``.

When the nodes or edges change, the view keeps the current positions and lets the
layout absorb the change, so adding a node does not scramble the graph.

## Using the layout without the view

Call ``ForceLayout/run()`` for a settled layout, iterate
``ForceLayout/stream(reportingEvery:minimumInterval:)`` to watch it settle, or drive a
``ForceLayout/Simulation`` from your own loop with ``ForceLayout/makeSimulation()``.
Pass the previous positions as ``ForceLayout/initialPositions`` to update a layout after
the graph changes without starting over.

```swift
let layout = ForceLayout(nodes: ["a", "b", "c"],
                         edges: [GraphEdge("a", "b"), GraphEdge("b", "c")])
let positions = layout.run()

var next = ForceLayout(nodes: ["a", "b", "c", "d"],
                       edges: [GraphEdge("a", "b"), GraphEdge("b", "c"), GraphEdge("c", "d")])
next.initialPositions = positions
let updated = next.run()
```

## Topics

### Layout

- ``ForceLayout``
- ``GraphEdge``
- ``ForceLayoutConfiguration``
- ``ForceLayout/Simulation``

### SwiftUI view

- ``ForceGraphView``
- ``ForceGraphStyle``
