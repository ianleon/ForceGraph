import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ForceGraph

@Suite struct ForceLayoutTests {
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func isFinite(_ positions: [some Hashable: CGPoint]) -> Bool {
        positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    @Test func sameInputsGiveSameLayout() {
        let layout = ForceLayout(nodes: ["a", "b", "c", "d"], edges: [.init("a", "b"), .init("b", "c")])
        #expect(layout.run() == layout.run())

        var other = layout
        other.configuration.seed += 1
        #expect(layout.run() != other.run())
    }

    @Test func edgeOrderAndDirectionDoNotChangeTheLayout() {
        let edges: [GraphEdge<String>] = [.init("a", "b"), .init("b", "c"), .init("c", "d"), .init("a", "d")]
        let layout = ForceLayout(nodes: ["a", "b", "c", "d"], edges: edges)
        let reversed = ForceLayout(nodes: ["a", "b", "c", "d"], edges: edges.reversed())
        let flipped = ForceLayout(nodes: ["a", "b", "c", "d"], edges: edges.map { .init($0.target, $0.source) })
        #expect(layout.run() == reversed.run())
        #expect(layout.run() == flipped.run())
    }

    @Test func connectedNodesEndUpCloserThanUnconnectedOnes() {
        let layout = ForceLayout(
            nodes: ["a", "b", "c", "lonely"],
            edges: [.init("a", "b"), .init("b", "c"), .init("a", "c")]
        )
        let p = layout.run()
        let ab = distance(p["a"]!, p["b"]!)
        let aLonely = distance(p["a"]!, p["lonely"]!)
        #expect(ab < aLonely)
    }

    @Test func emptyAndSingleNodeGraphs() {
        #expect(ForceLayout<Int>(nodes: [], edges: []).run().isEmpty)
        let single = ForceLayout(nodes: [7], edges: []).run()
        #expect(single.count == 1)
        #expect(single[7]!.x.isFinite && single[7]!.y.isFinite)
    }

    @Test func emptyGraphStillReportsOnce() async {
        let layout = ForceLayout<Int>(nodes: [], edges: [])
        var reports = 0
        _ = layout.run(reportingEvery: 8) { snapshot in
            reports += 1
            #expect(snapshot.isEmpty)
        }
        #expect(reports == 1)

        var snapshots: [[Int: CGPoint]] = []
        for await snapshot in layout.stream(minimumInterval: .zero) {
            snapshots.append(snapshot)
        }
        #expect(snapshots == [[:]])
    }

    @Test func ignoresSelfLoopsDuplicatesAndUnknownNodes() {
        let layout = ForceLayout(
            nodes: ["a", "b", "a"],
            edges: [.init("a", "a"), .init("a", "b"), .init("b", "a"), .init("a", "ghost")]
        )
        let p = layout.run()
        #expect(Set(p.keys) == ["a", "b"])

        let degrees = ForceLayout.degrees(nodes: ["a", "b", "a"], edges: layout.edges)
        #expect(degrees == ["a": 1, "b": 1])
    }

    @Test func largeGraphStaysFinite() {
        let nodes = Array(0..<200)
        var rng = SplitMix64(seed: 42)
        let edges = (0..<400).map { _ in
            GraphEdge(Int.random(in: 0..<200, using: &rng), Int.random(in: 0..<200, using: &rng))
        }
        let p = ForceLayout(nodes: nodes, edges: edges).run()
        #expect(p.count == 200)
        #expect(isFinite(p))
    }

    @Test func outOfRangeConfigurationStaysFinite() {
        var layout = ForceLayout(nodes: ["a", "b", "c"], edges: [.init("a", "b")])
        layout.configuration.area = 0
        #expect(isFinite(layout.run()))

        layout.configuration.area = -100
        #expect(isFinite(layout.run()))

        layout.configuration = .init()
        layout.configuration.cooling = 1.5
        layout.configuration.iterations = 2_000
        #expect(isFinite(layout.run()))

        layout.configuration = .init()
        layout.configuration.initialTemperature = -5
        layout.configuration.minimumTemperature = -5
        #expect(isFinite(layout.run()))
    }

    @Test func gravityPullsDisconnectedComponentsTogether() {
        var withGravity = ForceLayout(
            nodes: ["a", "b", "x", "y"],
            edges: [.init("a", "b"), .init("x", "y")]
        )
        var withoutGravity = withGravity
        withGravity.configuration.gravity = 0.03
        withoutGravity.configuration.gravity = 0

        func extent(_ positions: [String: CGPoint]) -> CGFloat {
            positions.values.map { hypot($0.x, $0.y) }.max() ?? 0
        }
        #expect(extent(withGravity.run()) < extent(withoutGravity.run()))
    }

    @Test func isolatedNodesStayNearTheCluster() {
        // A 95-node tree plus 5 orphans: the orphans must not dominate the bounding box.
        let nodes = Array(0..<100)
        let edges = (1..<95).map { GraphEdge($0, ($0 - 1) / 2) }
        let p = ForceLayout(nodes: nodes, edges: edges).run()
        let clusterRadius = (0..<95).map { hypot(p[$0]!.x, p[$0]!.y) }.max()!
        let orphanRadius = (95..<100).map { hypot(p[$0]!.x, p[$0]!.y) }.max()!
        #expect(orphanRadius <= clusterRadius * 2)
    }

    @Test func streamYieldsProgressAndEndsWithTheSettledLayout() async {
        let layout = ForceLayout(nodes: ["a", "b", "c"], edges: [.init("a", "b")])
        var snapshots: [[String: CGPoint]] = []
        for await snapshot in layout.stream(reportingEvery: 50) {
            snapshots.append(snapshot)
        }
        #expect(snapshots.count >= 2)
        #expect(snapshots.last == layout.run())
    }

    @Test func streamPacesSnapshots() async {
        var layout = ForceLayout(nodes: ["a", "b", "c"], edges: [.init("a", "b")])
        layout.configuration.iterations = 40
        let clock = ContinuousClock()
        let start = clock.now
        var count = 0
        for await _ in layout.stream(reportingEvery: 10, minimumInterval: .milliseconds(20)) {
            count += 1
        }
        // Four snapshots, three gaps of at least 20 ms between them.
        #expect(count == 4)
        #expect(clock.now - start >= .milliseconds(60))
    }

    @Test func cancellingTheConsumerStopsTheStream() async {
        let layout = ForceLayout(nodes: Array(0..<300), edges: [])
        let consumer = Task {
            var count = 0
            // Every step would be reported 50 ms apart; cancel after the first one.
            for await _ in layout.stream(reportingEvery: 1, minimumInterval: .milliseconds(50)) {
                count += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return count
        }
        let seen = await consumer.value
        #expect(seen <= 2)

        var last: [Int: CGPoint]?
        for await snapshot in layout.stream(reportingEvery: 50, minimumInterval: .zero) {
            last = snapshot
        }
        #expect(last == layout.run())
    }

    @Test func synchronousProgressReportsAtTheRequestedCadence() {
        var layout = ForceLayout(nodes: [1, 2, 3], edges: [.init(1, 2)])
        layout.configuration.iterations = 100
        var reported: [[Int: CGPoint]] = []
        let result = layout.run(reportingEvery: 10) { reported.append($0) }
        #expect(reported.count == 10)
        #expect(reported.last == result)
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 != $1 })

        // When the step count isn't a multiple, the final step is still reported.
        layout.configuration.iterations = 95
        var calls = 0
        _ = layout.run(reportingEvery: 10) { _ in calls += 1 }
        #expect(calls == 10)

        // Cadences below 1 report every step, as stream() does.
        calls = 0
        _ = layout.run(reportingEvery: 0) { _ in calls += 1 }
        #expect(calls == 95)
    }
}
