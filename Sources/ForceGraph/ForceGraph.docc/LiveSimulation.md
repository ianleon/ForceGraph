# The live simulation

Run a graph that keeps moving, reacts to dragging, and absorbs changes while it runs.

## Overview

``ForceSimulation`` is a port of d3-force's simulation to Swift. Unlike ``ForceLayout``,
which runs a fixed number of steps and hands back a finished layout, a simulation is a
long-lived value you advance once per display frame. It drifts while it is warm, cools to
a stop, and wakes up again whenever something changes: a node is dragged, a note is added,
a slider moves.

```swift
import ForceGraph

var simulation = ForceSimulation(
    nodes: ["Inbox", "Projects", "Ideas"],
    edges: [GraphEdge("Inbox", "Projects"), GraphEdge("Projects", "Ideas")],
    configuration: ObsidianGraphForces.defaults.configuration
)

// Once per frame, while it returns true:
simulation.step()
for (i, id) in simulation.nodes.enumerated() {
    let point = simulation.position(at: i)
    // draw `id` at `point`, with radius simulation.radius(at: i)
}
```

### Use the native view

```swift
import SwiftUI
import ForceGraph

ForceGraphView(nodes: ["Inbox", "Projects", "Ideas"],
               edges: [GraphEdge("Inbox", "Projects"), GraphEdge("Projects", "Ideas")]) { node in
    print(node)
}
.simulation(ObsidianGraphForces.defaults.configuration)
.nodeLabel { $0 }
```

Drag a node to hold it under the pointer while its neighbours respond. Releasing lets the
node move freely again. Drag empty space to pan. Pinch zoom, double-tap fit and `fitTrigger`
work in both presentations. Without `.simulation(...)`, the original fixed layout is used.
A settled live view stops requesting animation frames. With Reduce Motion, the view settles
without animation; the held node still follows the pointer.

### How a tick works

Each tick follows d3-force exactly:

1. ``ForceSimulation/alpha`` moves toward ``ForceSimulation/alphaTarget`` by
   ``ForceSimulationConfiguration/alphaDecay``. Alpha starts at 1; with the defaults it
   falls below ``ForceSimulationConfiguration/alphaMin`` (0.001) after 300 ticks, about five
   seconds at 60 frames per second, and the simulation is at rest
   (``ForceSimulation/isSettled``).
2. The forces add to each node's velocity, scaled by alpha, in this order:
   - **Link** (``ForceSimulationConfiguration/LinkForce``): a spring per link toward
     `distance`. By default its strength is d3's `1 / min(degree(source), degree(target))`,
     and the correction is split between the two ends by degree (d3's bias) so hubs move
     less than leaves.
   - **Many-body** (``ForceSimulationConfiguration/ManyBodyForce``): every pair repels with
     `strength / distance`, summed with a Barnes–Hut quadtree in O(n log n). `theta` trades
     accuracy for speed; 0 is the exact O(n²) sum.
   - **Position** (``ForceSimulationConfiguration/PositionForce``): a pull toward a point,
     proportional to distance (d3's `forceX` and `forceY`). It keeps orphans and separate
     components close, and makes the graph rounder as it grows.
   - **Collision** (``ForceSimulationConfiguration/CollisionForce``): nodes are discs that
     push apart when they would overlap. Radii grow with degree like ``ForceGraphView``'s,
     or come from ``ForceSimulation/setRadius(_:for:)``.
   - **Center** (``ForceSimulationConfiguration/CenterForce``): an optional translation
     that keeps the mean position on a point. Off by default, because re-centering while a
     node is held slides the rest of the graph away from the pointer.
3. Every free node keeps `1 - velocityDecay` of its velocity and moves by it. Every fixed
   node is put back at its fixed position with zero velocity.

The same graph, configuration, starting positions and sequence of calls always give the
same positions. Randomness is only used to separate nodes that sit exactly on top of each
other, and it comes from ``ForceSimulationConfiguration/seed``.

### Dragging

Dragging is the reason the simulation is live. Start a drag on touch-down or mouse-down,
move it with the pointer, end it on release:

```swift
simulation.beginDrag(id, at: pointInLayoutSpace)   // fixes the node, alphaTarget = 0.3
simulation.drag(id, to: pointInLayoutSpace)        // each pointer move
simulation.endDrag(id)                             // releases it, alphaTarget = 0
```

While a node is held its position is exactly the pointer's, and
``ForceSimulationConfiguration/dragAlphaTarget`` keeps the simulation warm so its
neighbours follow and the rest of the graph makes room. On release the node is let go, not
pinned, and the graph cools and settles again. Several nodes can be held at once, one per
finger. To pin a node permanently use ``ForceSimulation/fix(_:at:)`` and
``ForceSimulation/release(_:)``.

Find the node under the pointer with ``ForceSimulation/node(at:slop:)``, which respects
each node's radius and takes extra slop for fingers, or with
``ForceSimulation/nearestNode(to:within:)``, d3's `find`. Both are linear scans that take a
few microseconds at 5,000 nodes, cheap enough for every pointer move.

### Changing the graph while it runs

``ForceSimulation/update(nodes:edges:reheatingTo:)`` replaces the nodes and edges and keeps
the position, velocity and fixed position of every node that remains, so the picture does
not jump. New nodes start a short way out from the neighbours they link to, so an addition
grows out of where it connects; then the simulation is reheated to 0.3 to absorb it.
``ForceSimulation/add(_:at:reheatingTo:)`` and the `add` and `remove` methods for single
nodes and edges do the same for one change at a time.

Changing ``ForceSimulation/configuration`` takes effect on the next tick. Call
``ForceSimulation/reheat(to:)`` to watch the graph respond, as when a slider moves.

On a cold start, nodes are placed breadth first from the first node of each component, each
one a link length out from the node that reached it and heading away from it, so trees and
chains start untangled. A component's first node goes on d3-force's phyllotaxis spiral.

### Directed edges and arrows

The layout is undirected, but the simulation remembers which way each edge ran.
``ForceSimulation/edges`` lists the directed edges (without duplicates, self-loops or edges
to unknown nodes), and each of ``ForceSimulation/links``, the undirected pairs the layout
simulates, says whether an edge ran ``ForceSimulation/Link/isForward`` (from `source` to
`target`), ``ForceSimulation/Link/isBackward``, or both. Draw an arrowhead at each end an
edge points to.

### Reduce Motion

When the person has asked for reduced motion, don't animate the settling: call
``ForceSimulation/settle(maximumTicks:)`` and draw the result. After a drag, settle again
instead of stepping frame by frame.

### Running off the main actor

``ForceSimulation`` is a `Sendable` value type with no UI dependency. At 1,000 nodes a tick
costs about a millisecond, so ticking on the main actor is fine; for larger graphs keep it
in an actor and send the positions to the view each frame:

```swift
actor GraphEngine {
    private var simulation: ForceSimulation<String>

    init(nodes: [String], edges: [GraphEdge<String>]) {
        simulation = ForceSimulation(nodes: nodes, edges: edges,
                                     configuration: ObsidianGraphForces.defaults.configuration)
    }

    /// Advances one frame; nil once the graph is at rest.
    func frame() -> [CGPoint]? {
        simulation.step() ? simulation.positions() : nil
    }

    func beginDrag(_ id: String, at point: CGPoint) { simulation.beginDrag(id, at: point) }
}
```

Copying a simulation is cheap, but the first tick after a copy duplicates its arrays, so
send ``ForceSimulation/positions()`` rather than the simulation itself. A tick allocates
nothing once the simulation has run once: the Barnes–Hut and collision quadtrees are
rebuilt in place in buffers that keep their capacity.

## Obsidian's force sliders

``ObsidianGraphForces`` holds the four sliders in the Forces section of Obsidian's graph
view under the names, ranges and defaults Obsidian writes to `.obsidian/graph.json`, and
decodes from that file directly. Its ``ObsidianGraphForces/configuration`` maps them to a
simulation:

| Slider        | `graph.json` key | Range  | Default           | Simulation parameter                          |
|---------------|------------------|--------|-------------------|-----------------------------------------------|
| Center force  | `centerStrength` | 0…1    | 0.518713248970312 | position strength = value × 0.1               |
| Repel force   | `repelStrength`  | 0…20   | 10                | many-body strength = −value × 10              |
| Link force    | `linkStrength`   | 0…1    | 1                 | link strength = value / min(degrees) (d3's)   |
| Link distance | `linkDistance`   | 30…500 | 250               | link distance = value × 0.25 layout units     |

Obsidian's engine is not public, so the scale factors are ForceGraph's own, chosen so that:

- the defaults give a readable layout at ``ForceGraphView``'s node sizes, where a layout
  unit is a point at zoom 1: linked notes sit 60–90 points apart, nothing overlaps, orphans
  float at the edge of the graph instead of escaping, and the whole graph is round;
- each slider moves the layout the way Obsidian's does: more center force makes the graph
  more compact and circular, more repel force spreads it out, less link force loosens the
  links, more link distance lengthens them.

The test suite checks both on hand-made graphs (a tree with orphans, a star, a chain and two
cliques joined by a link). Everything the sliders don't control comes from the base
configuration passed to ``ObsidianGraphForces/configuration(base:)``.

## Performance

Per-tick cost with the Obsidian defaults on scale-free graphs (a few hubs, about 1.3 links
per node), the simulation held warm as while dragging, release build, best of five batches
of 20 ticks. `ForceSimulationPerformanceTests` records these numbers and fails if a tick
exceeds a 120 Hz frame (8.3 ms) at 1,000 nodes or a 60 Hz frame (16.7 ms) at 5,000:

| Nodes | Links | Mac (Apple M1 Max, `swift test`) | iPhone 18 Pro simulator (iOS 27) on that Mac |
|-------|-------|----------------------------------|----------------------------------------------|
| 1,000 | 1,333 | 0.95 ms                          | 1.3 ms                                       |
| 5,000 | 6,661 | 6.7 ms                           | 8.4 ms                                       |

Measured on 2026-10-19 while other builds were running on the machine, so these are on the
pessimistic side. Run them with
`swift test -c release -Xswiftc -enable-testing --filter ForceSimulationPerformance`, which
`Scripts/check.sh` does, or on a simulator with `xcodebuild test -configuration Release
ENABLE_TESTABILITY=YES -only-testing:ForceGraphTests/ForceSimulationPerformanceTests`.
Debug builds are roughly ten times slower.

## Credits

The simulation, its forces and its quadtree are ported from
[d3-force](https://github.com/d3/d3-force) and [d3-quadtree](https://github.com/d3/d3-quadtree)
by Mike Bostock, under the ISC License; see the package's NOTICE file.

## Topics

### Simulation

- ``ForceSimulation``
- ``ForceSimulationConfiguration``
- ``ForceSimulation/Link``

### Forces

- ``ForceSimulationConfiguration/LinkForce``
- ``ForceSimulationConfiguration/ManyBodyForce``
- ``ForceSimulationConfiguration/PositionForce``
- ``ForceSimulationConfiguration/CollisionForce``
- ``ForceSimulationConfiguration/CenterForce``

### Obsidian

- ``ObsidianGraphForces``
