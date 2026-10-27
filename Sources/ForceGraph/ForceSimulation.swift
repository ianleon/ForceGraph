import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A live force-directed simulation with d3-force semantics: it keeps moving while it is
/// warm, cools to a stop, and reheats when the graph changes or a node is dragged.
///
/// Where ``ForceLayout`` runs a fixed number of steps and returns a finished layout,
/// `ForceSimulation` is a long-lived state you advance with ``tick(_:)`` or ``step()``,
/// typically once per display frame, and change while it runs: drag a node with
/// ``beginDrag(_:at:)``, ``drag(_:to:)`` and ``endDrag(_:)``, pin one with
/// ``fix(_:at:)``, add and remove nodes and links with ``update(nodes:edges:reheatingTo:)``
/// without losing the positions of the rest.
///
/// Each tick follows d3-force: ``alpha`` moves toward ``alphaTarget`` by
/// ``ForceSimulationConfiguration/alphaDecay``; the link, many-body (Barnes–Hut), position
/// and collision forces add to each node's velocity, scaled by alpha; the center force
/// shifts the positions; then every free node keeps `1 - velocityDecay` of its velocity
/// and moves by it, and every fixed node is put back at its fixed position. The simulation
/// is at rest once alpha falls below ``ForceSimulationConfiguration/alphaMin``.
///
/// ```swift
/// var simulation = ForceSimulation(nodes: ["a", "b", "c"],
///                                  edges: [GraphEdge("a", "b"), GraphEdge("b", "c")])
/// while simulation.step() {}          // or one step() per frame
/// let positions = simulation.snapshot()
/// ```
///
/// It is a `Sendable` value type with no UI dependency, so it can live in an actor or a
/// background task and hand copies to the main actor for drawing. Copying is cheap until
/// one of the copies ticks. The same nodes, edges, configuration, starting positions and
/// sequence of calls always produce the same positions.
///
/// Cost per tick is O(n log n + m) for n nodes and m links; see <doc:LiveSimulation> for
/// measurements at 1,000 and 5,000 nodes.
public struct ForceSimulation<ID: Hashable & Sendable>: Sendable {
    /// A link between two nodes as the simulation stores it: indices into ``nodes``, the
    /// lower index first, and which directions the original edges ran.
    ///
    /// The layout treats links as undirected; the direction flags are there for drawing
    /// arrows. A pair linked both ways has both flags set.
    public struct Link: Hashable, Sendable {
        /// The index in ``ForceSimulation/nodes`` of one end, always lower than ``target``.
        public let source: Int
        /// The index in ``ForceSimulation/nodes`` of the other end.
        public let target: Int
        /// Whether some edge ran from ``source`` to ``target``.
        public let isForward: Bool
        /// Whether some edge ran from ``target`` to ``source``.
        public let isBackward: Bool
    }

    /// The tuning. Changing it takes effect on the next tick and does not reheat; call
    /// ``reheat(to:)`` to see the change play out.
    public var configuration: ForceSimulationConfiguration {
        didSet { refreshDerivedState() }
    }

    /// The simulation's temperature: forces are scaled by it, so the graph moves less as it
    /// cools. Starts at 1; set it directly, or use ``reheat(to:)``.
    public var alpha: Double

    /// The value alpha decays toward. 0 lets the simulation come to rest; a value above
    /// ``ForceSimulationConfiguration/alphaMin`` keeps it running, which is what dragging
    /// does. Default 0. As in d3-force, setting it does not wake a simulation that is at
    /// rest; call ``reheat(to:)`` too.
    public var alphaTarget: Double = 0

    /// The nodes, de-duplicated, in the order given. Indices in ``links``,
    /// ``position(at:)`` and ``radius(at:)`` refer to this array.
    public private(set) var nodes: [ID]

    /// The edges with their direction, as given but without self-loops, exact duplicates
    /// and edges to unknown nodes. Use them to draw arrows; the layout uses ``links``.
    public private(set) var edges: [GraphEdge<ID>]

    /// The undirected links the layout simulates, one per linked pair, sorted by index.
    public private(set) var links: [Link]

    /// The number of ticks taken so far.
    public private(set) var tickCount = 0

    private var index: [ID: Int]
    private var x: [Double]
    private var y: [Double]
    private var vx: [Double]
    private var vy: [Double]
    /// Fixed positions; NaN where the node is free.
    private var fx: [Double]
    private var fy: [Double]
    /// The radius each node is drawn and collides with, before padding.
    private var radii: [Double]
    /// Collision radii, with padding.
    private var collisionRadii: [Double]
    private var radiusOverrides: [ID: Double] = [:]
    private var degree: [Int]
    private var linkSource: [Int]
    private var linkTarget: [Int]
    private var linkStrength: [Double]
    private var linkBias: [Double]
    /// Predicted positions for the collision force.
    private var predictedX: [Double]
    private var predictedY: [Double]
    private var dragged: Set<ID> = []
    private var rng: SplitMix64
    private var tree = QuadTree()

    // MARK: Creating

    /// Creates a simulation of `nodes` and `edges` at temperature `alpha`.
    ///
    /// Nodes in `initialPositions` start there. The others start next to their positioned
    /// neighbours when they have some, and otherwise on d3-force's phyllotaxis spiral around
    /// the origin, which spreads them evenly without randomness. Duplicate nodes are
    /// ignored after their first occurrence, and so are self-loops, duplicate edges, edges
    /// to unknown nodes and non-finite positions.
    public init(
        nodes: [ID],
        edges: [GraphEdge<ID>],
        configuration: ForceSimulationConfiguration = .init(),
        initialPositions: [ID: CGPoint] = [:],
        alpha: Double = 1
    ) {
        self.configuration = configuration
        self.alpha = alpha
        self.nodes = []
        self.edges = []
        self.links = []
        self.index = [:]
        x = []; y = []; vx = []; vy = []; fx = []; fy = []
        radii = []; collisionRadii = []; degree = []
        linkSource = []; linkTarget = []; linkStrength = []; linkBias = []
        predictedX = []; predictedY = []
        rng = SplitMix64(seed: configuration.seed)
        replaceGraph(nodes: nodes, edges: edges, positions: initialPositions)
    }

    // MARK: Reading

    /// Whether the simulation has cooled below ``ForceSimulationConfiguration/alphaMin``.
    /// ``step()`` does nothing while it is at rest.
    public var isSettled: Bool {
        let minimum = configuration.alphaMin.isFinite ? max(configuration.alphaMin, 0) : 0.001
        return !(alpha >= minimum)
    }

    /// The index of `id` in ``nodes``.
    public func index(of id: ID) -> Int? { index[id] }

    /// The position of the node at `index` in ``nodes``. Cheap: use it in a drawing loop.
    public func position(at index: Int) -> CGPoint {
        CGPoint(x: x[index], y: y[index])
    }

    /// The position of `id`, or nil if it is not a node.
    public func position(of id: ID) -> CGPoint? {
        index[id].map { CGPoint(x: x[$0], y: y[$0]) }
    }

    /// The velocity of `id`, in layout units per tick, or nil if it is not a node.
    public func velocity(of id: ID) -> (dx: Double, dy: Double)? {
        index[id].map { (vx[$0], vy[$0]) }
    }

    /// The radius of the node at `index` (without the collision padding): its override
    /// from ``setRadius(_:for:)``, or the configured radius for its degree.
    public func radius(at index: Int) -> Double { radii[index] }

    /// The number of distinct neighbours of the node at `index`.
    public func degree(at index: Int) -> Int { degree[index] }

    /// The positions of every node.
    public func snapshot() -> [ID: CGPoint] {
        var result = [ID: CGPoint](minimumCapacity: nodes.count)
        for i in nodes.indices { result[nodes[i]] = CGPoint(x: x[i], y: y[i]) }
        return result
    }

    /// Every node's position, in the order of ``nodes``: a compact copy to hand to another
    /// actor for drawing.
    public func positions() -> [CGPoint] {
        var result = [CGPoint]()
        result.reserveCapacity(x.count)
        for i in x.indices { result.append(CGPoint(x: x[i], y: y[i])) }
        return result
    }

    /// The sum of the squared speeds of all nodes: zero when nothing moves.
    public var kineticEnergy: Double {
        var total = 0.0
        for i in x.indices { total += vx[i] * vx[i] + vy[i] * vy[i] }
        return total
    }

    /// The smallest rectangle containing every node's position, or nil without nodes.
    public var bounds: CGRect? {
        guard !x.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for i in x.indices {
            minX = min(minX, x[i]); maxX = max(maxX, x[i])
            minY = min(minY, y[i]); maxY = max(maxY, y[i])
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The node under `point`: the closest one whose radius plus `slop` reaches it, or nil.
    ///
    /// `slop` widens every node's hit area, in layout units, for fingers and small nodes.
    /// A linear scan, a few microseconds at 5,000 nodes, so it is fine for every pointer move.
    public func node(at point: CGPoint, slop: Double = 0) -> ID? {
        let px = Double(point.x), py = Double(point.y)
        var best = -1
        var bestDistance = Double.infinity
        for i in x.indices {
            let dx = x[i] - px, dy = y[i] - py
            let d2 = dx * dx + dy * dy
            let reach = radii[i] + slop
            if d2 <= reach * reach, d2 < bestDistance {
                best = i
                bestDistance = d2
            }
        }
        return best >= 0 ? nodes[best] : nil
    }

    /// The node closest to `point` within `radius`, regardless of node size (d3's `find`).
    public func nearestNode(to point: CGPoint, within radius: Double = .infinity) -> ID? {
        let px = Double(point.x), py = Double(point.y)
        var best = -1
        var bestDistance = radius * radius
        for i in x.indices {
            let dx = x[i] - px, dy = y[i] - py
            let d2 = dx * dx + dy * dy
            if d2 < bestDistance {
                best = i
                bestDistance = d2
            }
        }
        return best >= 0 ? nodes[best] : nil
    }

    /// The fixed position of `id`, or nil when it is free to move.
    public func fixedPosition(of id: ID) -> CGPoint? {
        guard let i = index[id], !fx[i].isNaN else { return nil }
        return CGPoint(x: fx[i], y: fy[i])
    }

    /// The nodes currently held by ``beginDrag(_:at:)``.
    public var draggedNodes: Set<ID> { dragged }

    // MARK: Running

    /// Advances the simulation by one tick if it is not at rest, and returns whether it is
    /// still running afterward. Call it once per frame and stop asking for frames when it
    /// returns false.
    @discardableResult
    public mutating func step() -> Bool {
        guard !isSettled else { return false }
        tick()
        return !isSettled
    }

    /// Advances the simulation by `count` ticks, whether or not it is at rest.
    public mutating func tick(_ count: Int = 1) {
        for _ in 0..<max(count, 0) { tickOnce() }
    }

    /// Runs the simulation until it comes to rest, for at most `maximumTicks` ticks, and
    /// returns the number of ticks taken. Use it to show a settled graph without animation,
    /// as when Reduce Motion is on.
    ///
    /// While ``alphaTarget`` is above ``ForceSimulationConfiguration/alphaMin`` (during a
    /// drag) the simulation never comes to rest, so this runs `maximumTicks` ticks.
    @discardableResult
    public mutating func settle(maximumTicks: Int = 1_000) -> Int {
        var ticks = 0
        while !isSettled, ticks < maximumTicks {
            tickOnce()
            ticks += 1
        }
        return ticks
    }

    /// Raises ``alpha`` to `value` (if it is lower), so the simulation runs again and
    /// absorbs whatever changed. d3-force's examples reheat to 1 after replacing the data and
    /// to 0.3 for smaller changes.
    public mutating func reheat(to value: Double = 1) {
        guard value.isFinite, value >= 0 else { return }
        alpha = alpha.isFinite ? max(alpha, value) : value
    }

    // MARK: Fixing and dragging

    /// Fixes `id` at `point`: it stays there, whatever the forces, until ``release(_:)``.
    /// The position applies from the next tick; the node also moves there immediately.
    public mutating func fix(_ id: ID, at point: CGPoint) {
        guard let i = index[id], point.x.isFinite, point.y.isFinite else { return }
        fx[i] = Double(point.x); fy[i] = Double(point.y)
        x[i] = fx[i]; y[i] = fy[i]
        vx[i] = 0; vy[i] = 0
    }

    /// Lets `id` move freely again from where it is.
    public mutating func release(_ id: ID) {
        guard let i = index[id] else { return }
        fx[i] = .nan; fy[i] = .nan
    }

    /// Moves `id` to `point` and stops it, without fixing it there.
    public mutating func setPosition(_ point: CGPoint, for id: ID) {
        guard let i = index[id], point.x.isFinite, point.y.isFinite else { return }
        x[i] = Double(point.x); y[i] = Double(point.y)
        vx[i] = 0; vy[i] = 0
        if !fx[i].isNaN { fx[i] = x[i]; fy[i] = y[i] }
    }

    /// Starts dragging `id`: fixes it at `point` and raises ``alphaTarget`` to
    /// ``ForceSimulationConfiguration/dragAlphaTarget``, so the rest of the graph keeps
    /// responding while it is held. Several nodes can be dragged at once (one per finger).
    public mutating func beginDrag(_ id: ID, at point: CGPoint) {
        guard index[id] != nil, point.x.isFinite, point.y.isFinite else { return }
        dragged.insert(id)
        fix(id, at: point)
        alphaTarget = configuration.dragAlphaTarget.isFinite ? max(configuration.dragAlphaTarget, 0) : 0.3
        reheat(to: alphaTarget)
    }

    /// Moves a dragged node to `point`. Nodes that are not being dragged are ignored.
    public mutating func drag(_ id: ID, to point: CGPoint) {
        guard dragged.contains(id) else { return }
        fix(id, at: point)
    }

    /// Ends dragging `id`: releases it, so it is not pinned where it was dropped, and once no
    /// node is held returns ``alphaTarget`` to 0 so the graph settles again.
    public mutating func endDrag(_ id: ID) {
        guard dragged.remove(id) != nil else { return }
        release(id)
        if dragged.isEmpty { alphaTarget = 0 }
    }

    /// Sets the radius `id` is drawn and collides with, or with nil returns it to the
    /// configured radius for its degree.
    public mutating func setRadius(_ radius: Double?, for id: ID) {
        guard let i = index[id] else { return }
        if let radius, radius.isFinite {
            radiusOverrides[id] = max(radius, 0)
        } else {
            radiusOverrides[id] = nil
        }
        radii[i] = nodeRadius(i)
        let padding = configuration.collision.padding
        collisionRadii[i] = radii[i] + (padding.isFinite ? max(padding, 0) : 0)
    }

    // MARK: Changing the graph

    /// Replaces the graph while the simulation runs, keeping every remaining node's
    /// position, velocity and fixed position, and raises ``alpha`` to `reheat` (if lower)
    /// so the graph absorbs the change.
    ///
    /// New nodes start next to their positioned neighbours (on a small spiral, so siblings
    /// do not coincide), or on the phyllotaxis spiral around the origin when they have none.
    /// Drags of removed nodes end. Pass `reheatingTo: 0` to change the graph without waking
    /// the simulation.
    public mutating func update(nodes newNodes: [ID], edges newEdges: [GraphEdge<ID>], reheatingTo reheat: Double = 0.3) {
        var kept: [ID: (Double, Double, Double, Double, Double, Double)] = [:]
        kept.reserveCapacity(nodes.count)
        for i in nodes.indices {
            kept[nodes[i]] = (x[i], y[i], vx[i], vy[i], fx[i], fy[i])
        }
        replaceGraph(nodes: newNodes, edges: newEdges, positions: [:], kept: kept)
        let wasDragging = !dragged.isEmpty
        dragged = dragged.filter { index[$0] != nil }
        if wasDragging, dragged.isEmpty { alphaTarget = 0 }
        self.reheat(to: reheat)
    }

    /// Adds a node, optionally at `point`, and reheats; a no-op if it is already a node.
    public mutating func add(_ id: ID, at point: CGPoint? = nil, reheatingTo reheat: Double = 0.3) {
        guard index[id] == nil else { return }
        update(nodes: nodes + [id], edges: edges, reheatingTo: reheat)
        if let point { setPosition(point, for: id) }
    }

    /// Removes a node and its edges, and reheats.
    public mutating func remove(_ id: ID, reheatingTo reheat: Double = 0.3) {
        guard index[id] != nil else { return }
        update(
            nodes: nodes.filter { $0 != id },
            edges: edges.filter { $0.source != id && $0.target != id },
            reheatingTo: reheat
        )
    }

    /// Adds an edge, and reheats.
    public mutating func add(_ edge: GraphEdge<ID>, reheatingTo reheat: Double = 0.3) {
        update(nodes: nodes, edges: edges + [edge], reheatingTo: reheat)
    }

    /// Removes an edge (in that direction), and reheats.
    public mutating func remove(_ edge: GraphEdge<ID>, reheatingTo reheat: Double = 0.3) {
        update(nodes: nodes, edges: edges.filter { $0 != edge }, reheatingTo: reheat)
    }
}

// MARK: - Internals

/// d3-force's initial placement: a phyllotaxis spiral, `10 × √(0.5 + i)` from the origin
/// at multiples of the golden angle.
private let initialRadius = 10.0
private let initialAngle = Double.pi * (3 - 5.0.squareRoot())

extension ForceSimulation {
    private mutating func replaceGraph(
        nodes newNodes: [ID],
        edges newEdges: [GraphEdge<ID>],
        positions: [ID: CGPoint],
        kept: [ID: (Double, Double, Double, Double, Double, Double)] = [:]
    ) {
        var seen = Set<ID>()
        let ids = newNodes.filter { seen.insert($0).inserted }
        let n = ids.count
        var index = [ID: Int](minimumCapacity: n)
        for (i, id) in ids.enumerated() { index[id] = i }

        // Directed edges, de-duplicated; then undirected pairs with their directions.
        var directed: [GraphEdge<ID>] = []
        var directedKeys = Set<Int>()
        var pairDirections: [Int: (forward: Bool, backward: Bool)] = [:]
        for edge in newEdges {
            guard let s = index[edge.source], let t = index[edge.target], s != t else { continue }
            guard directedKeys.insert(s * n + t).inserted else { continue }
            directed.append(edge)
            let key = min(s, t) * n + max(s, t)
            var flags = pairDirections[key] ?? (false, false)
            if s < t { flags.forward = true } else { flags.backward = true }
            pairDirections[key] = flags
        }
        let links = pairDirections
            .map { Link(source: $0.key / max(n, 1), target: $0.key % max(n, 1), isForward: $0.value.forward, isBackward: $0.value.backward) }
            .sorted { $0.source != $1.source ? $0.source < $1.source : $0.target < $1.target }

        var degree = [Int](repeating: 0, count: n)
        for link in links {
            degree[link.source] += 1
            degree[link.target] += 1
        }

        var x = [Double](repeating: .nan, count: n)
        var y = [Double](repeating: .nan, count: n)
        var vx = [Double](repeating: 0, count: n)
        var vy = [Double](repeating: 0, count: n)
        var fx = [Double](repeating: .nan, count: n)
        var fy = [Double](repeating: .nan, count: n)
        var placed = [Bool](repeating: false, count: n)
        for i in 0..<n {
            if let k = kept[ids[i]] {
                (x[i], y[i], vx[i], vy[i], fx[i], fy[i]) = k
                placed[i] = x[i].isFinite && y[i].isFinite
            } else if let p = positions[ids[i]], p.x.isFinite, p.y.isFinite {
                x[i] = Double(p.x); y[i] = Double(p.y)
                placed[i] = true
            }
        }

        placeUnplacedNodes(count: n, links: links, x: &x, y: &y, placed: placed)
        for i in 0..<n where !fx[i].isNaN {
            x[i] = fx[i]; y[i] = fy[i]
        }

        self.nodes = ids
        self.index = index
        self.edges = directed
        self.links = links
        self.degree = degree
        self.x = x; self.y = y; self.vx = vx; self.vy = vy; self.fx = fx; self.fy = fy
        self.linkSource = links.map(\.source)
        self.linkTarget = links.map(\.target)
        self.radiusOverrides = radiusOverrides.filter { index[$0.key] != nil }
        predictedX = [Double](repeating: 0, count: n)
        predictedY = [Double](repeating: 0, count: n)
        refreshDerivedState()
    }

    /// Gives every node without a position one, walking outward from the placed nodes so
    /// the starting layout already follows the graph's structure.
    ///
    /// Breadth-first from the placed nodes (in index order), each unplaced neighbour starts a
    /// short way out from the node that reached it, heading away from where that node came
    /// from and fanning out around that heading, so chains start straight and trees start
    /// branching instead of tangled. A component with no placed node starts at its
    /// lowest-index node, put on d3-force's phyllotaxis spiral around the origin. Without
    /// any placed node at all (a cold start) the steps are a link length; when nodes are
    /// added to a running graph they are short, so additions grow out of where they connect.
    private func placeUnplacedNodes(
        count n: Int, links: [Link], x: inout [Double], y: inout [Double], placed initiallyPlaced: [Bool]
    ) {
        var placed = initiallyPlaced
        guard placed.contains(false) else { return }
        let cold = !placed.contains(true)
        let distance = configuration.link.distance.isFinite ? max(configuration.link.distance, 1) : 30
        let step = cold ? distance : min(distance, 30) / 2

        // Adjacency in compressed form, neighbours in index order.
        var start = [Int](repeating: 0, count: n + 1)
        for link in links { start[link.source + 1] += 1; start[link.target + 1] += 1 }
        for i in 0..<n { start[i + 1] += start[i] }
        var fill = start
        var neighbours = [Int](repeating: 0, count: start[n])
        for link in links {
            neighbours[fill[link.source]] = link.target; fill[link.source] += 1
            neighbours[fill[link.target]] = link.source; fill[link.target] += 1
        }

        var heading = [Double](repeating: 0, count: n)
        var children = [Int](repeating: 0, count: n)
        var queue: [Int] = []
        queue.reserveCapacity(n)
        for i in 0..<n where placed[i] {
            heading[i] = Double(i) * initialAngle
            queue.append(i)
        }
        // The fan of headings around a parent's own: straight on, then alternately either
        // side, then around the circle by the golden angle.
        let fan: [Double] = [0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5]
        var head = 0
        var nextSeed = 0
        while true {
            while head < queue.count {
                let u = queue[head]
                head += 1
                for e in start[u]..<start[u + 1] {
                    let v = neighbours[e]
                    guard !placed[v] else { continue }
                    let k = children[u]
                    children[u] += 1
                    let angle = heading[u] + (k < fan.count ? fan[k] : Double(k) * initialAngle)
                    x[v] = x[u] + step * cos(angle)
                    y[v] = y[u] + step * sin(angle)
                    heading[v] = angle
                    placed[v] = true
                    queue.append(v)
                }
            }
            while nextSeed < n, placed[nextSeed] { nextSeed += 1 }
            guard nextSeed < n else { break }
            let i = nextSeed
            let angle = Double(i) * initialAngle
            let radius = initialRadius * (0.5 + Double(i)).squareRoot()
            x[i] = radius * cos(angle)
            y[i] = radius * sin(angle)
            heading[i] = angle
            placed[i] = true
            queue.append(i)
        }
    }

    /// Recomputes link strengths and biases and node radii from the configuration.
    private mutating func refreshDerivedState() {
        let n = nodes.count
        let collision = configuration.collision
        var radii = [Double](repeating: 0, count: n)
        var collisionRadii = [Double](repeating: 0, count: n)
        let padding = collision.padding.isFinite ? max(collision.padding, 0) : 0
        for i in 0..<n {
            radii[i] = nodeRadius(i)
            collisionRadii[i] = radii[i] + padding
        }
        self.radii = radii
        self.collisionRadii = collisionRadii

        let m = linkSource.count
        var strengths = [Double](repeating: 0, count: m)
        var biases = [Double](repeating: 0, count: m)
        for k in 0..<m {
            let s = Double(degree[linkSource[k]]), t = Double(degree[linkTarget[k]])
            biases[k] = s / (s + t)
            switch configuration.link.strength {
            case .degreeBased(let scale):
                strengths[k] = (scale.isFinite ? max(scale, 0) : 0) / min(s, t)
            case .constant(let value):
                strengths[k] = value.isFinite ? min(max(value, 0), 1) : 0
            }
        }
        linkStrength = strengths
        linkBias = biases
    }

    private func nodeRadius(_ i: Int) -> Double {
        if let override = radiusOverrides[nodes[i]] { return override }
        let c = configuration.collision
        let base = c.radius.isFinite ? max(c.radius, 0) : 0
        let growth = c.radiusPerSqrtDegree.isFinite ? c.radiusPerSqrtDegree : 0
        let r = base + growth * Double(degree[i]).squareRoot()
        let cap = c.maximumRadius.isFinite ? max(c.maximumRadius, base) : .infinity
        return min(max(r, 0), cap)
    }

    private mutating func tickOnce() {
        let config = configuration
        let decay = config.alphaDecay.isFinite ? min(max(config.alphaDecay, 0), 1) : 0
        // Public temperatures may come from malformed saved settings. Recover before
        // multiplying forces so a single non-finite value cannot poison every node.
        if !alpha.isFinite { alpha = 1 }
        let target = alphaTarget.isFinite ? max(alphaTarget, 0) : 0
        alpha += (target - alpha) * decay
        let alpha = self.alpha
        let n = nodes.count
        tickCount += 1
        guard n > 0 else { return }

        if !isKnownUniquelyReferenced(&tree) { tree = QuadTree() }
        let tree = self.tree
        var rng = self.rng

        // Move the arrays out so the kernels get exclusive, check-free access.
        var x = self.x, y = self.y, vx = self.vx, vy = self.vy
        var px = predictedX, py = predictedY
        self.x = []; self.y = []; self.vx = []; self.vy = []; predictedX = []; predictedY = []
        defer {
            self.x = x; self.y = y; self.vx = vx; self.vy = vy
            predictedX = px; predictedY = py
            self.rng = rng
        }

        x.withUnsafeMutableBufferPointer { xb in
        y.withUnsafeMutableBufferPointer { yb in
        vx.withUnsafeMutableBufferPointer { vxb in
        vy.withUnsafeMutableBufferPointer { vyb in
            let x = xb.baseAddress!, y = yb.baseAddress!, vx = vxb.baseAddress!, vy = vyb.baseAddress!

            // Link: springs, applied in place (later links see earlier links' changes).
            let link = config.link
            let distance = link.distance.isFinite ? max(link.distance, 0) : 0
            let m = linkSource.count
            if m > 0 {
                linkSource.withUnsafeBufferPointer { src in
                linkTarget.withUnsafeBufferPointer { dst in
                linkStrength.withUnsafeBufferPointer { strength in
                linkBias.withUnsafeBufferPointer { bias in
                    for _ in 0..<max(link.iterations, 1) {
                        for k in 0..<m {
                            let s = src[k], t = dst[k]
                            var dx = x[t] + vx[t] - x[s] - vx[s]
                            var dy = y[t] + vy[t] - y[s] - vy[s]
                            if dx == 0 || !dx.isFinite { dx = rng.jiggle() }
                            if dy == 0 || !dy.isFinite { dy = rng.jiggle() }
                            var l = (dx * dx + dy * dy).squareRoot()
                            l = (l - distance) / l * alpha * strength[k]
                            dx *= l; dy *= l
                            let b = bias[k]
                            vx[t] -= dx * b; vy[t] -= dy * b
                            vx[s] += dx * (1 - b); vy[s] += dy * (1 - b)
                        }
                    }
                }}}}
            }

            // Many-body: Barnes–Hut over the current positions.
            let body = config.manyBody
            if body.strength != 0, body.strength.isFinite {
                tree.build(count: n, x: x, y: y)
                tree.applyManyBody(
                    count: n, x: x, y: y, vx: vx, vy: vy,
                    strength: body.strength, alpha: alpha,
                    theta: body.theta.isFinite ? max(body.theta, 0) : 0,
                    distanceMin: body.distanceMin.isFinite ? max(body.distanceMin, 0) : 0,
                    distanceMax: body.distanceMax.isNaN ? .infinity : max(body.distanceMax, 0),
                    rng: &rng
                )
            }

            // Position: a pull toward a point.
            let position = config.position
            if position.strength != 0, position.strength.isFinite, position.x.isFinite, position.y.isFinite {
                let k = position.strength * alpha
                for i in 0..<n {
                    vx[i] += (position.x - x[i]) * k
                    vy[i] += (position.y - y[i]) * k
                }
            }

            // Collision: a quadtree over where the nodes are about to be.
            let collision = config.collision
            if collision.strength != 0, collision.strength.isFinite {
                px.withUnsafeMutableBufferPointer { pxb in
                py.withUnsafeMutableBufferPointer { pyb in
                collisionRadii.withUnsafeBufferPointer { radii in
                    let px = pxb.baseAddress!, py = pyb.baseAddress!
                    for _ in 0..<max(collision.iterations, 1) {
                        for i in 0..<n {
                            px[i] = x[i] + vx[i]
                            py[i] = y[i] + vy[i]
                        }
                        tree.build(count: n, x: px, y: py)
                        tree.applyCollision(
                            count: n, x: x, y: y, vx: vx, vy: vy, px: px, py: py,
                            radii: radii.baseAddress!, strength: min(max(collision.strength, 0), 1),
                            rng: &rng
                        )
                    }
                }}}
            }

            // Center: shift everything so the mean lands on the centre.
            let center = config.center
            if center.strength != 0, center.strength.isFinite, center.x.isFinite, center.y.isFinite {
                var sx = 0.0, sy = 0.0
                for i in 0..<n { sx += x[i]; sy += y[i] }
                sx = (sx / Double(n) - center.x) * center.strength
                sy = (sy / Double(n) - center.y) * center.strength
                for i in 0..<n { x[i] -= sx; y[i] -= sy }
            }

            // Integrate: keep 1 - velocityDecay of the velocity, then move; fixed nodes stay.
            let keep = 1 - (config.velocityDecay.isFinite ? min(max(config.velocityDecay, 0), 1) : 0.4)
            fx.withUnsafeBufferPointer { fx in
            fy.withUnsafeBufferPointer { fy in
                for i in 0..<n {
                    if fx[i].isNaN {
                        vx[i] *= keep
                        x[i] += vx[i]
                    } else {
                        x[i] = fx[i]
                        vx[i] = 0
                    }
                    if fy[i].isNaN {
                        vy[i] *= keep
                        y[i] += vy[i]
                    } else {
                        y[i] = fy[i]
                        vy[i] = 0
                    }
                }
            }}
        }}}}
    }
}
