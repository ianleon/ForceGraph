import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An undirected edge between two node identifiers.
public struct GraphEdge<ID: Hashable & Sendable>: Hashable, Sendable {
    public var source: ID
    public var target: ID

    public init(_ source: ID, _ target: ID) {
        self.source = source
        self.target = target
    }
}

/// Tuning for ``ForceLayout``. The defaults give a readable layout for graphs
/// of a few hundred nodes; raise `area` for larger graphs or more spacing.
///
/// Out-of-range values are clamped rather than rejected: `area` to a small positive
/// number, `cooling` to 0…1, temperatures to zero or more.
public struct ForceLayoutConfiguration: Hashable, Sendable {
    /// Number of simulation steps. More steps settle better; 200 is plenty for most graphs.
    public var iterations = 200
    /// The square area (in layout units) the nodes should spread over. Spacing scales with `sqrt(area / nodeCount)`. Must be positive.
    public var area: Double = 360_000
    /// Maximum displacement per step at the start; decays by `cooling` each step.
    public var initialTemperature: Double = 120
    /// Multiplier applied to the temperature after every step (0 ≤ cooling ≤ 1).
    public var cooling: Double = 0.96
    /// The temperature never drops below this, so the layout keeps a little life until the end.
    public var minimumTemperature: Double = 1.5
    /// Pull toward the origin, proportional to distance. Keeps disconnected components and
    /// isolated nodes from drifting away: a lone node settles about `sqrt(area / gravity)`
    /// units out (850 with the defaults), so weaker gravity lets orphans dominate the bounds.
    public var gravity: Double = 0.5
    /// Seed for the initial positions. The same seed, nodes, edges and configuration always produce the same layout.
    public var seed: UInt64 = 0x5EED

    public init() {}
}

/// Fruchterman–Reingold force-directed layout: connected nodes attract,
/// all nodes repel, and a cooling schedule lets the system settle.
///
/// The layout is pure and deterministic — no UI dependency — so it can drive a
/// SwiftUI `Canvas`, an AppKit view, or a test. Positions are centered around the origin.
/// Node order seeds the initial positions and edge order does not matter, so pass
/// `nodes` in a stable order when they come from a `Set` or `Dictionary`.
///
/// Complexity is O(n²) per step, which is comfortable up to roughly 1,500 nodes.
/// ``run()`` is synchronous (about a second at that size on a Mac, longer on a phone,
/// much longer in debug builds), so run large graphs off the main thread or use ``stream(reportingEvery:minimumInterval:)``.
public struct ForceLayout<ID: Hashable & Sendable>: Sendable {
    public var nodes: [ID]
    public var edges: [GraphEdge<ID>]
    public var configuration: ForceLayoutConfiguration

    public init(nodes: [ID], edges: [GraphEdge<ID>], configuration: ForceLayoutConfiguration = .init()) {
        self.nodes = nodes
        self.edges = edges
        self.configuration = configuration
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

    /// Runs the full simulation synchronously and returns the final positions.
    public func run() -> [ID: CGPoint] {
        var simulation = Simulation(self)
        while !simulation.isFinished { simulation.step() }
        return simulation.snapshot()
    }

    /// Runs the full simulation synchronously, calling `progress` every `every` steps
    /// (and after the final step) with the positions so far. Values below 1 report every step.
    public func run(reportingEvery every: Int, progress: ([ID: CGPoint]) -> Void) -> [ID: CGPoint] {
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
    /// steps, ending with the settled layout.
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

/// The simulation state for one ``ForceLayout`` run, advanced one step at a time so
/// synchronous and streaming callers share the same code.
struct Simulation<ID: Hashable & Sendable> {
    private let ids: [ID]
    private let edges: [(Int, Int)]
    private let k: Double
    private let gravity: Double
    private let cooling: Double
    private let minimumTemperature: Double
    private let iterations: Int
    private var temperature: Double
    private var rng: SplitMix64
    private var px: [Double]
    private var py: [Double]
    private var dx: [Double]
    private var dy: [Double]

    /// Steps taken so far.
    private(set) var completedSteps = 0

    var isFinished: Bool { completedSteps >= iterations }

    init(_ layout: ForceLayout<ID>) {
        let graph = NormalizedGraph(nodes: layout.nodes, edges: layout.edges)
        let config = layout.configuration
        let n = graph.ids.count
        let area = max(config.area, 1e-9)

        ids = graph.ids
        edges = graph.edges
        k = (area / Double(max(n, 1))).squareRoot()
        gravity = config.gravity
        cooling = min(max(config.cooling, 0), 1)
        minimumTemperature = max(config.minimumTemperature, 0)
        temperature = max(config.initialTemperature, 0)
        // An empty graph takes a single no-op step so callers still receive one report.
        iterations = n == 0 ? 1 : max(config.iterations, 1)
        rng = SplitMix64(seed: config.seed)

        let spread = area.squareRoot() / 2
        px = [Double](repeating: 0, count: n)
        py = [Double](repeating: 0, count: n)
        for i in 0..<n {
            // Uniform in a disk, so the first frame already looks like a graph.
            let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
            let r = spread * Double.random(in: 0...1, using: &rng).squareRoot()
            px[i] = r * cos(angle)
            py[i] = r * sin(angle)
        }
        dx = [Double](repeating: 0, count: n)
        dy = [Double](repeating: 0, count: n)
    }

    /// The current positions keyed by node.
    func snapshot() -> [ID: CGPoint] {
        var result = [ID: CGPoint](minimumCapacity: ids.count)
        for i in ids.indices { result[ids[i]] = CGPoint(x: px[i], y: py[i]) }
        return result
    }

    /// Advances the simulation by one step. Does nothing once finished.
    mutating func step() {
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
struct SplitMix64: RandomNumberGenerator {
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
