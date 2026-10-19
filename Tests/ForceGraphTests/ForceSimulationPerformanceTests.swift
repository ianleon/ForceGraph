import Foundation
import Testing
import ForceGraph

/// Milliseconds per tick at 1,000 and 5,000 nodes, with the Obsidian default forces and the
/// simulation held warm (alpha 0.3, as while a node is dragged): the best of 5 batches of
/// 20 ticks, so a busy machine skews the result less.
///
/// Timings only mean something in an optimized build, so in debug builds the test runs a
/// few ticks to check it works and does not compare against the budgets. Run it with:
///
///     swift test -c release -Xswiftc -enable-testing --filter ForceSimulationPerformance
///
/// (`Scripts/check.sh` does.) Recorded on 2026-10-19, release build:
///
/// | Nodes | Links | Apple M-series Mac (arm64) | iPhone 18 Pro simulator |
/// |-------|-------|----------------------------|-------------------------|
/// | 1,000 | 1,333 | 0.9 ms                     | see <doc:LiveSimulation> |
/// | 5,000 | 6,661 | 6.4 ms                     | see <doc:LiveSimulation> |
///
/// The budgets are deliberately looser than those numbers so slower machines pass: a
/// 120 Hz frame (8.3 ms) at 1,000 nodes and a 60 Hz frame (16.7 ms) at 5,000.
@Suite(.serialized) struct ForceSimulationPerformanceTests {
    #if DEBUG
    static let optimized = false
    #else
    static let optimized = true
    #endif

    private func millisecondsPerTick(nodes count: Int, batches: Int, ticks: Int) -> Double {
        let graph = Graphs.scaleFree(count)
        var simulation = ForceSimulation(
            nodes: graph.nodes, edges: graph.edges,
            configuration: ObsidianGraphForces.defaults.configuration
        )
        simulation.tick(Self.optimized ? 10 : 1)   // warm up: grow the scratch buffers
        simulation.alpha = 0.3
        simulation.alphaTarget = 0.3
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0..<batches {
            let elapsed = clock.measure { simulation.tick(ticks) }
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            best = min(best, seconds * 1000 / Double(ticks))
        }
        #expect(simulation.snapshot().values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        return best
    }

    @Test(arguments: [(1_000, 8.3), (5_000, 16.7)])
    func millisecondsPerTick(nodes: Int, budget: Double) {
        let ms = Self.optimized
            ? millisecondsPerTick(nodes: nodes, batches: 5, ticks: 20)
            : millisecondsPerTick(nodes: nodes, batches: 1, ticks: 1)
        print("ForceSimulation: \(nodes) nodes, \(String(format: "%.2f", ms)) ms per tick (\(Self.optimized ? "release" : "debug"))")
        if Self.optimized {
            #expect(ms < budget, "\(nodes) nodes took \(ms) ms per tick; the budget is \(budget) ms")
        }
    }
}
