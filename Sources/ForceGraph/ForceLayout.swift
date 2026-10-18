import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An undirected edge between two node identifiers.
///
/// Undirected: `GraphEdge(a, b)` and `GraphEdge(b, a)` are the same edge. `source` and
/// `target` only preserve the order the edge was created with. Duplicate and reversed
/// pairs collapse to one edge, and self-loops are ignored, both in ``ForceLayout`` and in
/// ``ForceGraphView``; ``ForceLayout/uniqueEdges`` lists the edges that remain.
public struct GraphEdge<ID: Hashable & Sendable>: Hashable, Sendable {
    /// One end of the edge. Order does not matter: the edge is undirected.
    public var source: ID
    /// The other end of the edge.
    public var target: ID

    /// Creates an undirected edge between `source` and `target`.
    public init(_ source: ID, _ target: ID) {
        self.source = source
        self.target = target
    }
}

extension GraphEdge: Codable where ID: Codable {}

extension GraphEdge: CustomStringConvertible {
    /// The two ends, as `source -- target`.
    public var description: String { "\(source) -- \(target)" }
}

/// Tuning for ``ForceLayout``. The defaults give a readable layout for graphs
/// of a few hundred nodes; raise `area` for larger graphs or more spacing.
///
/// Out-of-range values are clamped rather than rejected: `area` to a small positive
/// number, `cooling` to 0…1, temperatures to zero or more, `iterations` to at least 1.
/// `gravity` is used as given; negative values push nodes away from the origin.
///
/// Change a single knob inline with the memberwise initializer:
///
/// ```swift
/// let layout = ForceLayout(nodes: ids, edges: edges,
///                          configuration: ForceLayoutConfiguration(area: 640_000))
/// ```
public struct ForceLayoutConfiguration: Hashable, Sendable {
    /// Number of simulation steps. More steps settle better; 200 is plenty for most graphs.
    /// Values below 1 run a single step.
    public var iterations: Int
    /// The square area (in layout units) the nodes should spread over. Spacing scales with
    /// `sqrt(area / nodeCount)`. Zero or negative values are clamped to a tiny positive area.
    public var area: Double
    /// Maximum displacement per step at the start of a cold layout (one without
    /// ``ForceLayout/initialPositions``); decays by `cooling` each step.
    public var initialTemperature: Double
    /// Maximum displacement per step at the start of a warm start, used instead of
    /// `initialTemperature` when ``ForceLayout/initialPositions`` places at least one node.
    /// During a warm start the temperature then cools toward zero rather than
    /// `minimumTemperature`, so the layout absorbs the change and comes to rest instead of
    /// drifting. Lower values keep an existing layout steadier; zero keeps it exactly in place.
    public var warmStartTemperature: Double
    /// Multiplier applied to the temperature after every step (0 ≤ cooling ≤ 1).
    public var cooling: Double
    /// The temperature of a cold layout never drops below this, so it keeps a little life
    /// until the end. A warm start cools toward zero instead.
    public var minimumTemperature: Double
    /// Pull toward the origin, proportional to distance. Keeps disconnected components and
    /// isolated nodes from drifting away: a lone node settles about `sqrt(area / gravity)`
    /// units out (850 with the defaults), so weaker gravity lets orphans dominate the bounds.
    public var gravity: Double
    /// Seed for the initial positions. The same seed, nodes, edges, initial positions and
    /// configuration always produce the same layout.
    public var seed: UInt64

    /// Creates a configuration. Every parameter defaults to a tuning suitable for graphs
    /// of a few hundred nodes, so pass only what you want to change.
    public init(
        iterations: Int = 200,
        area: Double = 360_000,
        initialTemperature: Double = 120,
        warmStartTemperature: Double = 10,
        cooling: Double = 0.96,
        minimumTemperature: Double = 1.5,
        gravity: Double = 0.5,
        seed: UInt64 = 0x5EED
    ) {
        self.iterations = iterations
        self.area = area
        self.initialTemperature = initialTemperature
        self.warmStartTemperature = warmStartTemperature
        self.cooling = cooling
        self.minimumTemperature = minimumTemperature
        self.gravity = gravity
        self.seed = seed
    }
}

/// Fruchterman–Reingold force-directed layout: connected nodes attract,
/// all nodes repel, and a cooling schedule lets the system settle.
///
/// The layout is pure and deterministic — no UI dependency — so it can drive a
/// SwiftUI `Canvas`, an AppKit view, or a test. Positions are centered around the origin.
/// Node order seeds the initial positions and edge order does not matter, so pass
/// `nodes` in a stable order when they come from a `Set` or `Dictionary`.
///
/// To update a layout after the graph changes without scrambling it, pass the previous
/// positions as ``initialPositions``: known nodes start where they were, new nodes start
/// next to their positioned neighbours, and the simulation starts at the gentler
/// ``ForceLayoutConfiguration/warmStartTemperature`` and cools toward zero.
///
/// Complexity is O(n²) per step, which is comfortable up to roughly 1,500 nodes.
/// ``run()`` is synchronous (about a second at that size on a Mac, longer on a phone,
/// much longer in debug builds), so run large graphs off the main thread or use
/// ``stream(reportingEvery:minimumInterval:)``.
public struct ForceLayout<ID: Hashable & Sendable>: Hashable, Sendable {
    /// Node identifiers. Duplicates are ignored after their first occurrence, and the
    /// order seeds the initial positions.
    public var nodes: [ID]
    /// Undirected edges. Self-loops, duplicates and edges to unknown nodes are ignored.
    public var edges: [GraphEdge<ID>]
    /// Simulation tuning.
    public var configuration: ForceLayoutConfiguration
    /// Starting positions for a warm start, typically the result of an earlier run.
    ///
    /// Nodes listed here start at their position; nodes missing from it start next to
    /// their positioned neighbours, or at a seeded random position when they have none.
    /// Entries for unknown nodes and non-finite points are ignored. When at least one node
    /// is placed, the simulation starts at ``ForceLayoutConfiguration/warmStartTemperature``
    /// instead of ``ForceLayoutConfiguration/initialTemperature`` and cools toward zero, so
    /// the layout comes to rest near where it started. Part of the input: the same initial
    /// positions give the same layout.
    public var initialPositions: [ID: CGPoint]

    /// Creates a layout for `nodes` and `edges`; nothing runs until ``run()``,
    /// ``stream(reportingEvery:minimumInterval:)`` or ``makeSimulation()`` is called.
    public init(
        nodes: [ID],
        edges: [GraphEdge<ID>],
        configuration: ForceLayoutConfiguration = .init(),
        initialPositions: [ID: CGPoint] = [:]
    ) {
        self.nodes = nodes
        self.edges = edges
        self.configuration = configuration
        self.initialPositions = initialPositions
    }

    // Written out because `CGPoint` is not `Hashable` on every platform and SDK.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.nodes == rhs.nodes && lhs.edges == rhs.edges
            && lhs.configuration == rhs.configuration && lhs.initialPositions == rhs.initialPositions
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(nodes)
        hasher.combine(edges)
        hasher.combine(configuration)
        hasher.combine(initialPositions.count)
    }

    /// Number of distinct neighbours of each node. Self-loops, duplicate edges and
    /// edges mentioning unknown nodes are ignored, matching what the layout simulates.
    public static func degrees(nodes: [ID], edges: [GraphEdge<ID>]) -> [ID: Int] {
        let graph = NormalizedGraph(nodes: nodes, edges: edges)
        var degrees = [ID: Int](minimumCapacity: graph.ids.count)
        for id in graph.ids { degrees[id] = 0 }
        for (s, t) in graph.edges {
            degrees[graph.ids[s], default: 0] += 1
            degrees[graph.ids[t], default: 0] += 1
        }
        return degrees
    }

    /// Number of distinct neighbours of each node, as ``degrees(nodes:edges:)`` counts them.
    public var degrees: [ID: Int] { Self.degrees(nodes: nodes, edges: edges) }

    /// The edges the layout simulates: one per unordered pair of distinct known nodes.
    ///
    /// Duplicates, reversed pairs, self-loops and edges to unknown nodes are dropped. Each
    /// edge's `source` is the end that comes first in ``nodes``, and the edges are sorted
    /// by node order, so the result does not depend on the input's edge order.
    public var uniqueEdges: [GraphEdge<ID>] {
        let graph = NormalizedGraph(nodes: nodes, edges: edges)
        return graph.edges.map { GraphEdge(graph.ids[$0.0], graph.ids[$0.1]) }
    }

    /// Creates the simulation for this layout, ready to be advanced one step at a time.
    ///
    /// Use it to drive the layout from your own loop, such as a `TimelineView`, a display
    /// link or a game loop; ``run()`` and ``stream(reportingEvery:minimumInterval:)`` are
    /// built on it and produce the same positions.
    public func makeSimulation() -> Simulation {
        Simulation(self)
    }

    /// Runs the full simulation synchronously and returns the final positions.
    public func run() -> [ID: CGPoint] {
        var simulation = Simulation(self)
        while !simulation.isFinished { simulation.step() }
        return simulation.snapshot()
    }

    /// Runs the full simulation synchronously, calling `progress` every `every` steps
    /// (and after the final step) with the positions so far, on the caller's thread.
    /// Values below 1 report every step.
    public func run(reportingEvery every: Int = 8, progress: ([ID: CGPoint]) -> Void) -> [ID: CGPoint] {
        let every = max(every, 1)
        var simulation = Simulation(self)
        while !simulation.isFinished {
            simulation.step()
            if simulation.completedSteps % every == 0 || simulation.isFinished {
                progress(simulation.snapshot())
            }
        }
        return simulation.snapshot()
    }

    /// Runs the simulation on a background task and yields a snapshot every `every`
    /// steps, ending with the settled layout. Values below 1 report every step.
    ///
    /// Snapshots are delivered at most once per `minimumInterval` so the layout is seen
    /// settling even when the simulation is fast; pass `.zero` for no pacing. A consumer
    /// that falls behind receives the newest snapshot rather than a backlog. The work starts
    /// when the stream is created, and cancelling the consuming task stops it.
    public func stream(
        reportingEvery every: Int = 8,
        minimumInterval: Duration = .milliseconds(25)
    ) -> AsyncStream<[ID: CGPoint]> {
        let every = max(every, 1)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var simulation = Simulation(self)
                let clock = ContinuousClock()
                var lastYield: ContinuousClock.Instant?
                while !simulation.isFinished, !Task.isCancelled {
                    simulation.step()
                    guard simulation.completedSteps % every == 0 || simulation.isFinished else { continue }
                    if let lastYield {
                        try? await Task.sleep(until: lastYield + minimumInterval, clock: clock)
                        if Task.isCancelled { break }
                    }
                    continuation.yield(simulation.snapshot())
                    lastYield = clock.now
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Simulation

extension ForceLayout {
    /// The state of one ``ForceLayout`` run, advanced one step at a time.
    ///
    /// Create one with ``ForceLayout/makeSimulation()``, call ``step()`` until
    /// ``isFinished``, and read ``snapshot()`` whenever you want to draw. Stepping to the
    /// end gives exactly what ``ForceLayout/run()`` returns.
    ///
    /// ```swift
    /// var simulation = layout.makeSimulation()
    /// while !simulation.isFinished {
    ///     simulation.step()
    /// }
    /// let positions = simulation.snapshot()
    /// ```
    public struct Simulation: Sendable {
        private let ids: [ID]
        private let edges: [(Int, Int)]
        private let k: Double
        private let gravity: Double
        private let cooling: Double
        private let minimumTemperature: Double
        private var temperature: Double
        private var rng: SplitMix64
        private var px: [Double]
        private var py: [Double]
        private var dx: [Double]
        private var dy: [Double]

        /// The number of steps the simulation takes in total. An empty graph takes a single
        /// no-op step so progress callers still receive one report.
        public let totalSteps: Int

        /// Steps taken so far.
        public private(set) var completedSteps = 0

        /// Whether every step has been taken; ``step()`` does nothing from then on.
        public var isFinished: Bool { completedSteps >= totalSteps }

        init(_ layout: ForceLayout) {
            let graph = NormalizedGraph(nodes: layout.nodes, edges: layout.edges)
            let config = layout.configuration
            let n = graph.ids.count
            let area = max(config.area, 1e-9)

            ids = graph.ids
            edges = graph.edges
            k = (area / Double(max(n, 1))).squareRoot()
            gravity = config.gravity
            cooling = min(max(config.cooling, 0), 1)
            totalSteps = n == 0 ? 1 : max(config.iterations, 1)
            rng = SplitMix64(seed: config.seed)

            let spread = area.squareRoot() / 2
            var px = [Double](repeating: 0, count: n)
            var py = [Double](repeating: 0, count: n)
            var angles = [Double](repeating: 0, count: n)
            var placed = [Bool](repeating: false, count: n)
            for i in 0..<n {
                // Uniform in a disk, so the first frame already looks like a graph. The draws
                // happen for every node, placed or not, so a node's random start does not
                // depend on which other nodes have initial positions.
                let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
                let r = spread * Double.random(in: 0...1, using: &rng).squareRoot()
                angles[i] = angle
                if let p = layout.initialPositions[graph.ids[i]], p.x.isFinite, p.y.isFinite {
                    px[i] = Double(p.x)
                    py[i] = Double(p.y)
                    placed[i] = true
                } else {
                    px[i] = r * cos(angle)
                    py[i] = r * sin(angle)
                }
            }

            let warm = placed.contains(true)
            if warm {
                // New nodes start half a spacing unit from the centre of their placed
                // neighbours, so an addition grows out of where it connects.
                var sumX = [Double](repeating: 0, count: n)
                var sumY = [Double](repeating: 0, count: n)
                var count = [Int](repeating: 0, count: n)
                for (s, t) in graph.edges where placed[s] != placed[t] {
                    let (from, to) = placed[s] ? (s, t) : (t, s)
                    sumX[to] += px[from]
                    sumY[to] += py[from]
                    count[to] += 1
                }
                for i in 0..<n where !placed[i] && count[i] > 0 {
                    px[i] = sumX[i] / Double(count[i]) + k / 2 * cos(angles[i])
                    py[i] = sumY[i] / Double(count[i]) + k / 2 * sin(angles[i])
                }
            }
            // A warm start cools toward zero so a layout that already looks right comes to rest.
            temperature = max(warm ? config.warmStartTemperature : config.initialTemperature, 0)
            minimumTemperature = warm ? 0 : max(config.minimumTemperature, 0)

            self.px = px
            self.py = py
            dx = [Double](repeating: 0, count: n)
            dy = [Double](repeating: 0, count: n)
        }

        /// The current positions keyed by node.
        public func snapshot() -> [ID: CGPoint] {
            var result = [ID: CGPoint](minimumCapacity: ids.count)
            for i in ids.indices { result[ids[i]] = CGPoint(x: px[i], y: py[i]) }
            return result
        }

        /// Advances the simulation by one step. Does nothing once finished.
        public mutating func step() {
            guard !isFinished else { return }
            let n = ids.count
            for i in 0..<n { dx[i] = 0; dy[i] = 0 }

            // Repulsion between every pair: k² / d.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var vx = px[i] - px[j]
                    var vy = py[i] - py[j]
                    var dist = (vx * vx + vy * vy).squareRoot()
                    if dist < 0.01 {
                        vx = Double.random(in: -1...1, using: &rng)
                        vy = Double.random(in: -1...1, using: &rng)
                        dist = 1
                    }
                    let force = (k * k / dist) / dist
                    dx[i] += vx * force; dy[i] += vy * force
                    dx[j] -= vx * force; dy[j] -= vy * force
                }
            }

            // Attraction along edges: d² / k.
            for (s, t) in edges {
                let vx = px[s] - px[t]
                let vy = py[s] - py[t]
                let dist = max((vx * vx + vy * vy).squareRoot(), 0.01)
                let force = (dist * dist / k) / dist
                dx[s] -= vx * force; dy[s] -= vy * force
                dx[t] += vx * force; dy[t] += vy * force
            }

            // Gravity toward the origin, then move by at most `temperature`.
            for i in 0..<n {
                dx[i] -= px[i] * gravity
                dy[i] -= py[i] * gravity
                let disp = max((dx[i] * dx[i] + dy[i] * dy[i]).squareRoot(), 0.01)
                let limit = min(disp, temperature)
                px[i] += dx[i] / disp * limit
                py[i] += dy[i] / disp * limit
            }
            temperature = max(temperature * cooling, minimumTemperature)
            completedSteps += 1
        }
    }
}

/// Nodes de-duplicated in order, edges reduced to unique undirected pairs of known,
/// distinct nodes, expressed as sorted indices into `ids` so the input's edge order
/// cannot change the layout.
struct NormalizedGraph<ID: Hashable & Sendable> {
    let ids: [ID]
    let edges: [(Int, Int)]

    init(nodes: [ID], edges: [GraphEdge<ID>]) {
        var seen = Set<ID>()
        let ids = nodes.filter { seen.insert($0).inserted }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var pairs: [(Int, Int)] = []
        var pairKeys = Set<Int>()
        for edge in edges {
            guard let s = index[edge.source], let t = index[edge.target], s != t else { continue }
            let (lo, hi) = s < t ? (s, t) : (t, s)
            if pairKeys.insert(lo * ids.count + hi).inserted {
                pairs.append((lo, hi))
            }
        }
        pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        self.ids = ids
        self.edges = pairs
    }
}

/// Small, fast, seedable generator so layouts are reproducible.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
