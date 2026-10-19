import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
import ForceGraph

/// Hand-made graphs shared by the simulation tests.
enum Graphs {
    /// A 100-node binary tree plus 5 orphans (nodes 100…104), the shape of a small vault.
    static let tree = (nodes: Array(0..<105), edges: (1..<100).map { GraphEdge($0, ($0 - 1) / 2) })
    /// One hub linked to 40 leaves.
    static let star = (nodes: Array(0...40), edges: (1...40).map { GraphEdge(0, $0) })
    /// A path of 20 nodes.
    static let chain = (nodes: Array(0..<20), edges: (1..<20).map { GraphEdge($0 - 1, $0) })
    /// Two 6-cliques joined by one link.
    static let barbell: (nodes: [Int], edges: [GraphEdge<Int>]) = {
        var edges: [GraphEdge<Int>] = []
        for base in [0, 6] {
            for i in 0..<6 { for j in (i + 1)..<6 { edges.append(GraphEdge(base + i, base + j)) } }
        }
        edges.append(GraphEdge(5, 6))
        return (Array(0..<12), edges)
    }()

    /// A preferential-attachment graph, like a vault with a few hub notes: `n` nodes,
    /// about 1.3 links per node.
    static func scaleFree(_ n: Int, seed: UInt64 = 3) -> (nodes: [Int], edges: [GraphEdge<Int>]) {
        var state = seed
        func next() -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int(truncatingIfNeeded: (z ^ (z >> 31)) >> 1)
        }
        var ends = [0]
        var edges: [GraphEdge<Int>] = []
        for i in 1..<n {
            for _ in 0..<(next() % 3 == 0 ? 2 : 1) {
                let t = ends[next() % ends.count]
                edges.append(GraphEdge(i, t))
                ends.append(t)
            }
            ends.append(i)
        }
        return (Array(0..<n), edges)
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    Double(hypot(a.x - b.x, a.y - b.y))
}

// Serialized: these tests are CPU-bound, and running them all at once would occupy every
// thread of the cooperative pool and starve the timing-sensitive stream tests.
@Suite(.serialized) struct ForceSimulationTests {
    private func settled<ID>(_ nodes: [ID], _ edges: [GraphEdge<ID>],
                             _ configuration: ForceSimulationConfiguration = .init()) -> ForceSimulation<ID> {
        var simulation = ForceSimulation(nodes: nodes, edges: edges, configuration: configuration)
        simulation.settle()
        return simulation
    }

    // MARK: Cooling

    @Test func energySettlesAndTheSimulationStops() {
        var simulation = ForceSimulation(nodes: Graphs.tree.nodes, edges: Graphs.tree.edges)
        #expect(simulation.alpha == 1)
        #expect(!simulation.isSettled)

        var energies: [Double] = []
        while simulation.step() { energies.append(simulation.kineticEnergy) }
        // d3's schedule: alpha falls from 1 below alphaMin (0.001) in 300 ticks.
        #expect(simulation.tickCount == 300)
        #expect(simulation.isSettled)
        #expect(simulation.alpha < 0.001)

        let peak = energies.max()!
        let late = energies.suffix(20).max()!
        #expect(late < peak * 1e-3)
        #expect(simulation.snapshot().values.allSatisfy { $0.x.isFinite && $0.y.isFinite })

        // At rest, step() does nothing.
        let positions = simulation.snapshot()
        let stepped = simulation.step()
        #expect(!stepped)
        #expect(simulation.tickCount == 300)
        #expect(simulation.snapshot() == positions)
    }

    @Test func settleRunsToRestAndReportsTheTicks() {
        var simulation = ForceSimulation(nodes: Graphs.star.nodes, edges: Graphs.star.edges)
        let first = simulation.settle()
        #expect(first == 300)
        #expect(simulation.isSettled)
        let again = simulation.settle()
        #expect(again == 0)

        // Held by a drag, it never rests, so settle stops at its limit.
        simulation.beginDrag(1, at: CGPoint(x: 50, y: 50))
        let held = simulation.settle(maximumTicks: 40)
        #expect(held == 40)
        #expect(!simulation.isSettled)
    }

    @Test func reheatWakesASettledSimulation() {
        var simulation = settled(Graphs.tree.nodes, Graphs.tree.edges)
        let rest = simulation.snapshot()

        // Knock one node out of place; nothing happens until the simulation is reheated.
        let home = rest[7]!
        simulation.setPosition(CGPoint(x: home.x + 300, y: home.y), for: 7)
        let woke = simulation.step()
        #expect(!woke)
        #expect(simulation.position(of: 7)!.x == home.x + 300)

        simulation.reheat(to: 0.5)
        #expect(simulation.alpha == 0.5)
        simulation.reheat(to: 0.1)
        #expect(simulation.alpha == 0.5, "reheating never cools")
        let running = simulation.step()
        #expect(running)
        simulation.settle()
        #expect(simulation.isSettled)
        // The springs pulled it most of the way back toward its neighbourhood.
        #expect(distance(simulation.position(of: 7)!, simulation.position(of: 3)!) < 200)
        #expect(distance(simulation.position(of: 7)!, home) < 150)
    }

    @Test func alphaTargetKeepsTheSimulationRunning() {
        var simulation = settled(Graphs.chain.nodes, Graphs.chain.edges)
        simulation.alphaTarget = 0.2
        simulation.reheat(to: 0.001)
        for _ in 0..<500 { simulation.step() }
        #expect(!simulation.isSettled)
        #expect(abs(simulation.alpha - 0.2) < 0.01)
        simulation.alphaTarget = 0
        simulation.settle()
        #expect(simulation.isSettled)
    }

    // MARK: Fixed nodes and dragging

    @Test func fixedNodesStayPut() {
        var simulation = ForceSimulation(nodes: Graphs.tree.nodes, edges: Graphs.tree.edges)
        let pin = CGPoint(x: 400, y: -250)
        simulation.fix(0, at: pin)
        #expect(simulation.position(of: 0) == pin)
        #expect(simulation.fixedPosition(of: 0) == pin)
        for _ in 0..<150 {
            simulation.tick()
            #expect(simulation.position(of: 0) == pin)
        }
        // Its children were pulled toward the pinned root.
        #expect(distance(simulation.position(of: 1)!, pin) < 200)

        simulation.release(0)
        #expect(simulation.fixedPosition(of: 0) == nil)
        simulation.tick(20)
        #expect(simulation.position(of: 0) != pin)
    }

    @Test func fixedNodesStayPutUnderTheCenterForce() {
        var configuration = ForceSimulationConfiguration()
        configuration.center.strength = 1
        var simulation = ForceSimulation(nodes: Graphs.star.nodes, edges: Graphs.star.edges, configuration: configuration)
        simulation.fix(3, at: CGPoint(x: 500, y: 500))
        simulation.tick(50)
        #expect(simulation.position(of: 3) == CGPoint(x: 500, y: 500))
    }

    @Test func draggingANodeMovesItsNeighboursAndReleasesItAfterwards() {
        var simulation = settled(Graphs.tree.nodes, Graphs.tree.edges, ObsidianGraphForces.defaults.configuration)
        let before = simulation.snapshot()
        let grab = 2
        let start = before[grab]!

        simulation.beginDrag(grab, at: start)
        #expect(simulation.draggedNodes == [grab])
        #expect(simulation.alphaTarget == 0.3)
        #expect(!simulation.isSettled)

        // Pull it 400 units to the right over 40 frames, then hold it there for 60.
        for frame in 1...100 {
            let target = CGPoint(x: start.x + 10 * CGFloat(min(frame, 40)), y: start.y)
            simulation.drag(grab, to: target)
            simulation.step()
            #expect(simulation.position(of: grab) == target, "the node follows the pointer exactly")
            if frame == 40 {
                // Its children are already on their way.
                for child in [5, 6] { #expect(simulation.position(of: child)!.x - before[child]!.x > 50) }
            }
        }
        // By now the children have caught up, and the nodes nearest it in the tree moved
        // more than the far side of the graph did.
        func moved(_ id: Int) -> Double { distance(simulation.position(of: id)!, before[id]!) }
        for child in [5, 6] { #expect(moved(child) > 150) }
        let near = [5, 6, 11, 12, 13, 14].map(moved).reduce(0, +) / 6
        let far = [3, 7, 8, 15, 16, 17].map(moved).reduce(0, +) / 6
        #expect(near > far * 2, "near \(near), far \(far)")

        simulation.endDrag(grab)
        #expect(simulation.draggedNodes.isEmpty)
        #expect(simulation.alphaTarget == 0)
        #expect(simulation.fixedPosition(of: grab) == nil, "dropped, not pinned")
        let dropped = simulation.position(of: grab)!
        simulation.settle()
        #expect(simulation.isSettled)
        #expect(simulation.position(of: grab) != dropped, "it moves with the graph again")
    }

    @Test func dragsAreIgnoredForNodesThatAreNotHeld() {
        var simulation = ForceSimulation(nodes: ["a", "b"], edges: [GraphEdge("a", "b")])
        let a = simulation.position(of: "a")!
        simulation.drag("a", to: CGPoint(x: 999, y: 999))
        #expect(simulation.position(of: "a") == a)
        #expect(simulation.fixedPosition(of: "a") == nil)
        simulation.endDrag("a")
        simulation.beginDrag("ghost", at: .zero)
        #expect(simulation.draggedNodes.isEmpty)

        // Two fingers: the target stays up until the last one lifts.
        simulation.beginDrag("a", at: .zero)
        simulation.beginDrag("b", at: CGPoint(x: 100, y: 0))
        simulation.endDrag("a")
        #expect(simulation.alphaTarget == 0.3)
        simulation.endDrag("b")
        #expect(simulation.alphaTarget == 0)
    }

    // MARK: Changing the graph while it runs

    @Test func addingANodeKeepsTheOthersWhereTheyAre() {
        var simulation = settled(Graphs.tree.nodes, Graphs.tree.edges, ObsidianGraphForces.defaults.configuration)
        let before = simulation.snapshot()

        simulation.update(nodes: Graphs.tree.nodes + [200], edges: Graphs.tree.edges + [GraphEdge(200, 40)], reheatingTo: 0)
        for (id, point) in before {
            #expect(simulation.position(of: id) == point)
        }
        let spacing = ObsidianGraphForces.defaults.configuration.link.distance
        #expect(distance(simulation.position(of: 200)!, before[40]!) <= spacing)
        #expect(simulation.isSettled, "reheatingTo: 0 leaves it asleep")

        simulation.reheat(to: 0.3)
        simulation.settle()
        let xs = before.values.map(\.x), ys = before.values.map(\.y)
        let extent = Double(max(xs.max()! - xs.min()!, ys.max()! - ys.min()!))
        let movement = before.map { distance($0.value, simulation.position(of: $0.key)!) }.reduce(0, +) / Double(before.count)
        #expect(movement < extent * 0.05, "the graph absorbs the new node without rearranging")
        #expect(distance(simulation.position(of: 200)!, simulation.position(of: 40)!) < spacing * 2)
    }

    @Test func updatesKeepVelocitiesFixedPositionsAndDrags() {
        var simulation = ForceSimulation(nodes: Graphs.chain.nodes, edges: Graphs.chain.edges)
        simulation.tick(10)
        simulation.beginDrag(3, at: CGPoint(x: 77, y: 33))
        let velocity = simulation.velocity(of: 8)!
        simulation.update(nodes: Graphs.chain.nodes + [99], edges: Graphs.chain.edges)
        #expect(simulation.velocity(of: 8)! == velocity)
        #expect(simulation.fixedPosition(of: 3) == CGPoint(x: 77, y: 33))
        #expect(simulation.draggedNodes == [3])
        #expect(simulation.alpha >= 0.3)

        // Removing the dragged node ends its drag.
        simulation.remove(3)
        #expect(simulation.draggedNodes.isEmpty)
        #expect(simulation.alphaTarget == 0)
        #expect(simulation.index(of: 3) == nil)
        #expect(!simulation.edges.contains { $0.source == 3 || $0.target == 3 })
    }

    @Test func addingAndRemovingNodesAndEdgesOneAtATime() {
        var simulation = settled(Graphs.chain.nodes, Graphs.chain.edges)
        let before = simulation.snapshot()

        simulation.add(50, at: CGPoint(x: 10, y: 20), reheatingTo: 0)
        #expect(simulation.position(of: 50) == CGPoint(x: 10, y: 20))
        simulation.add(50)
        #expect(simulation.nodes.count == 21)

        simulation.add(GraphEdge(50, 0))
        #expect(simulation.links.count == 20)
        #expect(simulation.alpha >= 0.3)
        simulation.remove(GraphEdge(50, 0), reheatingTo: 0)
        #expect(simulation.links.count == 19)
        simulation.remove(50, reheatingTo: 0)
        #expect(simulation.nodes == Graphs.chain.nodes)
        for (id, point) in before { #expect(simulation.position(of: id) == point) }
    }

    // MARK: Barnes–Hut

    /// The velocity one tick adds to each node, with only the many-body force on and no
    /// friction or cooling, so the velocity is exactly the force.
    private func manyBodyForces(_ positions: [CGPoint], theta: Double) -> [(dx: Double, dy: Double)] {
        var configuration = ForceSimulationConfiguration(alphaDecay: 0, velocityDecay: 0)
        configuration.link.strength = .constant(0)
        configuration.position.strength = 0
        configuration.collision.strength = 0
        configuration.manyBody = .init(strength: -30, theta: theta)
        let ids = Array(positions.indices)
        var initial: [Int: CGPoint] = [:]
        for i in ids { initial[i] = positions[i] }
        var simulation = ForceSimulation(nodes: ids, edges: [], configuration: configuration, initialPositions: initial)
        simulation.tick()
        return ids.map { simulation.velocity(of: $0)! }
    }

    /// The exact O(n²) many-body force, written out from d3-force's definition.
    private func exactForces(_ positions: [CGPoint], strength: Double = -30, distanceMin: Double = 1) -> [(dx: Double, dy: Double)] {
        positions.indices.map { i in
            var fx = 0.0, fy = 0.0
            for j in positions.indices where j != i {
                let dx = Double(positions[j].x - positions[i].x), dy = Double(positions[j].y - positions[i].y)
                var l = dx * dx + dy * dy
                if l < distanceMin * distanceMin { l = (distanceMin * distanceMin * l).squareRoot() }
                fx += dx * strength / l
                fy += dy * strength / l
            }
            return (fx, fy)
        }
    }

    private func randomPoints(_ n: Int, seed: UInt64) -> [CGPoint] {
        var state = seed
        func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        // Clumpy, like a real graph: a few dense clusters and a sparse background.
        return (0..<n).map { i in
            if i % 3 == 0 { return CGPoint(x: unit() * 2000 - 1000, y: unit() * 2000 - 1000) }
            let cluster = Double(i % 5) * 300 - 600
            return CGPoint(x: cluster + unit() * 120, y: -cluster * 0.5 + unit() * 120)
        }
    }

    @Test func barnesHutMatchesTheExactForce() {
        let points = randomPoints(800, seed: 11)
        let exact = exactForces(points)

        // theta = 0 never approximates: it is the exact sum, up to rounding.
        let zero = manyBodyForces(points, theta: 0)
        for (a, e) in zip(zero, exact) {
            #expect(abs(a.dx - e.dx) <= 1e-9 * max(1, abs(e.dx)))
            #expect(abs(a.dy - e.dy) <= 1e-9 * max(1, abs(e.dy)))
        }

        // d3's default theta of 0.9: each node's force is within a few percent.
        let approx = manyBodyForces(points, theta: 0.9)
        var errors: [Double] = []
        for (a, e) in zip(approx, exact) {
            let magnitude = (e.dx * e.dx + e.dy * e.dy).squareRoot()
            let error = ((a.dx - e.dx) * (a.dx - e.dx) + (a.dy - e.dy) * (a.dy - e.dy)).squareRoot()
            errors.append(error / magnitude)
        }
        errors.sort()
        let median = errors[errors.count / 2]
        let p95 = errors[errors.count * 95 / 100]
        #expect(median < 0.02, "median relative error \(median)")
        #expect(p95 < 0.08, "95th percentile relative error \(p95)")

        // A tighter theta is more accurate.
        let tight = manyBodyForces(points, theta: 0.5)
        let tightMedian = zip(tight, exact).map { a, e in
            ((a.dx - e.dx) * (a.dx - e.dx) + (a.dy - e.dy) * (a.dy - e.dy)).squareRoot()
                / (e.dx * e.dx + e.dy * e.dy).squareRoot()
        }.sorted()[points.count / 2]
        #expect(tightMedian < median)
    }

    @Test func coincidentNodesAreSeparatedDeterministically() {
        let ids = Array(0..<30)
        let origin = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGPoint.zero) })
        var a = ForceSimulation(nodes: ids, edges: [], initialPositions: origin)
        var b = ForceSimulation(nodes: ids, edges: [], initialPositions: origin)
        var other = ForceSimulation(nodes: ids, edges: [], configuration: .init(seed: 99), initialPositions: origin)
        a.settle(); b.settle(); other.settle()
        #expect(a.snapshot() == b.snapshot())
        #expect(a.snapshot() != other.snapshot())
        let points = Array(a.snapshot().values)
        for i in points.indices {
            for j in (i + 1)..<points.count {
                #expect(distance(points[i], points[j]) > 4, "the jiggle and the collision force separate them")
            }
        }
    }

    @Test func collisionKeepsNodesApart() {
        var configuration = ForceSimulationConfiguration()
        configuration.manyBody.strength = 0
        configuration.position.strength = 0.2
        var simulation = ForceSimulation(nodes: Array(0..<60), edges: [], configuration: configuration)
        simulation.settle()
        for i in 0..<60 {
            for j in (i + 1)..<60 {
                let gap = distance(simulation.position(at: i), simulation.position(at: j))
                    - simulation.radius(at: i) - simulation.radius(at: j)
                #expect(gap > -0.5)
            }
        }
    }

    // MARK: Obsidian's defaults

    private func overlaps(_ simulation: ForceSimulation<Int>) -> Bool {
        let n = simulation.nodes.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                let gap = distance(simulation.position(at: i), simulation.position(at: j))
                    - simulation.radius(at: i) - simulation.radius(at: j)
                if gap < 0 { return true }
            }
        }
        return false
    }

    @Test func obsidianDefaultsLayOutATreeWithOrphansReadably() {
        let simulation = settled(Graphs.tree.nodes, Graphs.tree.edges, ObsidianGraphForces.defaults.configuration)
        let p = simulation.snapshot()
        #expect(!overlaps(simulation))

        // Linked nodes sit close together, near the link distance.
        let linkDistance = ObsidianGraphForces.defaults.configuration.link.distance
        let linkLengths = Graphs.tree.edges.map { distance(p[$0.source]!, p[$0.target]!) }
        let meanLink = linkLengths.reduce(0, +) / Double(linkLengths.count)
        #expect(meanLink > linkDistance * 0.8 && meanLink < linkDistance * 2)

        // Orphans float near the cluster instead of escaping.
        let centre = (0..<100).reduce(CGPoint.zero) { CGPoint(x: $0.x + p[$1]!.x / 100, y: $0.y + p[$1]!.y / 100) }
        let clusterRadius = (0..<100).map { distance(p[$0]!, centre) }.max()!
        let orphanRadius = (100..<105).map { distance(p[$0]!, centre) }.max()!
        #expect(orphanRadius < clusterRadius * 1.6)
        // And the graph is centred near the origin.
        #expect(distance(centre, .zero) < clusterRadius * 0.2)
    }

    @Test func obsidianDefaultsSpreadAStarEvenly() {
        let simulation = settled(Graphs.star.nodes, Graphs.star.edges, ObsidianGraphForces.defaults.configuration)
        let hub = simulation.position(of: 0)!
        let spokes = (1...40).map { distance(simulation.position(of: $0)!, hub) }
        let mean = spokes.reduce(0, +) / 40
        let deviation = (spokes.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 40).squareRoot()
        #expect(deviation / mean < 0.15)
        #expect(!overlaps(simulation))
    }

    @Test func obsidianDefaultsUnfoldAChain() {
        let simulation = settled(Graphs.chain.nodes, Graphs.chain.edges, ObsidianGraphForces.defaults.configuration)
        let linkDistance = ObsidianGraphForces.defaults.configuration.link.distance
        let span = distance(simulation.position(of: 0)!, simulation.position(of: 19)!)
        // Not crumpled into a ball: the ends are far apart.
        #expect(span > linkDistance * 19 * 0.25, "span \(span)")
        #expect(!overlaps(simulation))
    }

    @Test func obsidianDefaultsKeepCliquesTogetherAndApart() {
        let simulation = settled(Graphs.barbell.nodes, Graphs.barbell.edges, ObsidianGraphForces.defaults.configuration)
        let p = simulation.snapshot()
        func centre(_ ids: Range<Int>) -> CGPoint {
            let sum = ids.reduce(CGPoint.zero) { CGPoint(x: $0.x + p[$1]!.x, y: $0.y + p[$1]!.y) }
            return CGPoint(x: sum.x / CGFloat(ids.count), y: sum.y / CGFloat(ids.count))
        }
        let left = centre(0..<6), right = centre(6..<12)
        let within = (0..<6).map { distance(p[$0]!, left) }.max()!
        #expect(distance(left, right) > within * 2, "the two cliques are visibly separate")
        #expect(!overlaps(simulation))
    }

    @Test func obsidianSlidersMoveTheLayoutTheExpectedWay() {
        func extent(_ forces: ObsidianGraphForces) -> Double {
            let simulation = settled(Graphs.tree.nodes, Graphs.tree.edges, forces.configuration)
            let b = simulation.bounds!
            return Double(max(b.width, b.height))
        }
        func meanLink(_ forces: ObsidianGraphForces) -> Double {
            let simulation = settled(Graphs.tree.nodes, Graphs.tree.edges, forces.configuration)
            let p = simulation.snapshot()
            return Graphs.tree.edges.map { distance(p[$0.source]!, p[$0.target]!) }.reduce(0, +) / 99
        }
        #expect(extent(.init(centerStrength: 1)) < extent(.init(centerStrength: 0.2)))
        #expect(extent(.init(repelStrength: 20)) > extent(.init(repelStrength: 2)))
        #expect(meanLink(.init(linkDistance: 500)) > meanLink(.init(linkDistance: 30)))
        #expect(meanLink(.init(linkStrength: 0.1)) > meanLink(.init(linkStrength: 1)))
    }

    // MARK: Graph structure and API

    @Test func edgesKeepTheirDirectionForArrows() {
        let simulation = ForceSimulation(
            nodes: ["a", "b", "c"],
            edges: [.init("a", "b"), .init("b", "a"), .init("a", "b"), .init("c", "a"), .init("c", "c"), .init("a", "ghost")]
        )
        #expect(simulation.edges == [GraphEdge("a", "b"), GraphEdge("b", "a"), GraphEdge("c", "a")])
        #expect(simulation.links.count == 2)
        let ab = simulation.links[0], ac = simulation.links[1]
        #expect((ab.source, ab.target) == (0, 1))
        #expect(ab.isForward && ab.isBackward)
        #expect((ac.source, ac.target) == (0, 2))
        #expect(!ac.isForward && ac.isBackward, "the only edge runs from c to a")
        #expect(simulation.degree(at: 0) == 2)
    }

    @Test func sameInputsGiveTheSamePositions() {
        var a = ForceSimulation(nodes: Graphs.tree.nodes, edges: Graphs.tree.edges)
        var b = ForceSimulation(nodes: Graphs.tree.nodes, edges: Graphs.tree.edges.reversed())
        a.tick(120); b.tick(120)
        #expect(a.snapshot() == b.snapshot(), "edge order does not matter")
    }

    @Test func runsOffTheMainActor() async {
        let graph = Graphs.scaleFree(300)
        let background = await Task.detached {
            var simulation = ForceSimulation(nodes: graph.nodes, edges: graph.edges)
            simulation.settle()
            return simulation
        }.value
        var here = ForceSimulation(nodes: graph.nodes, edges: graph.edges)
        here.settle()
        #expect(background.snapshot() == here.snapshot())
    }

    @Test func copiesTickIndependently() {
        var a = ForceSimulation(nodes: Graphs.star.nodes, edges: Graphs.star.edges)
        a.tick(10)
        var b = a
        let frozen = a.snapshot()
        b.tick(10)
        #expect(a.snapshot() == frozen)
        a.tick(10)
        #expect(a.snapshot() == b.snapshot())
        #expect(a.positions() == a.nodes.map { a.position(of: $0)! })
    }

    @Test func hitTestingFindsTheNodeUnderAPoint() {
        var simulation = ForceSimulation(nodes: ["a", "b"], edges: [])
        simulation.setPosition(CGPoint(x: 0, y: 0), for: "a")
        simulation.setPosition(CGPoint(x: 100, y: 0), for: "b")
        simulation.setRadius(10, for: "b")
        #expect(simulation.radius(at: 1) == 10)
        #expect(simulation.node(at: CGPoint(x: 3, y: 0)) == "a")
        #expect(simulation.node(at: CGPoint(x: 91, y: 0)) == "b")
        #expect(simulation.node(at: CGPoint(x: 50, y: 0)) == nil)
        #expect(simulation.node(at: CGPoint(x: 50, y: 0), slop: 45) == "b")
        #expect(simulation.nearestNode(to: CGPoint(x: 40, y: 0)) == "a")
        #expect(simulation.nearestNode(to: CGPoint(x: 40, y: 500), within: 100) == nil)
        simulation.setRadius(nil, for: "b")
        #expect(simulation.radius(at: 1) == 4, "back to the configured radius for degree 0")
    }

    @Test func changingTheConfigurationTakesEffect() {
        var simulation = settled(Graphs.star.nodes, Graphs.star.edges)
        func meanSpoke() -> Double {
            let hub = simulation.position(of: 0)!
            return (1...40).map { distance(simulation.position(of: $0)!, hub) }.reduce(0, +) / 40
        }
        let before = meanSpoke()
        simulation.configuration.link.distance = 150
        simulation.reheat()
        simulation.settle()
        #expect(meanSpoke() > before * 1.5, "\(meanSpoke()) vs \(before)")

        simulation.configuration.collision.radius = 9
        simulation.configuration.collision.radiusPerSqrtDegree = 0
        #expect(simulation.radius(at: 5) == 9)
    }

    @Test func emptyAndDegenerateInputsStayFinite() {
        var empty = ForceSimulation<Int>(nodes: [], edges: [])
        empty.settle()
        #expect(empty.snapshot().isEmpty)
        #expect(empty.bounds == nil)
        #expect(empty.node(at: .zero) == nil)

        var single = ForceSimulation(nodes: [1], edges: [GraphEdge(1, 1)])
        single.settle()
        #expect(single.position(of: 1)!.x.isFinite)

        var configuration = ForceSimulationConfiguration(alphaDecay: .nan, velocityDecay: 7)
        configuration.manyBody.theta = -.infinity
        configuration.link.distance = .nan
        configuration.collision.padding = .infinity
        var odd = ForceSimulation(nodes: Graphs.star.nodes, edges: Graphs.star.edges, configuration: configuration)
        odd.tick(50)
        #expect(odd.snapshot().values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
}

@Suite struct ObsidianGraphForcesTests {
    @Test func decodesARealGraphJSON() throws {
        let json = """
        {"collapse-filter":true,"search":"","showTags":false,"showAttachments":false,"hideUnresolved":false,
        "showOrphans":true,"collapse-color-groups":true,"colorGroups":[],"collapse-display":true,"showArrow":false,
        "textFadeMultiplier":0,"nodeSizeMultiplier":1,"lineSizeMultiplier":1,"collapse-forces":true,
        "centerStrength":0.518713248970312,"repelStrength":10,"linkStrength":1,"linkDistance":250,"scale":1,"close":false}
        """
        let forces = try JSONDecoder().decode(ObsidianGraphForces.self, from: Data(json.utf8))
        #expect(forces == .defaults)
        #expect(forces == ObsidianGraphForces())

        let partial = try JSONDecoder().decode(ObsidianGraphForces.self, from: Data(#"{"repelStrength":3}"#.utf8))
        #expect(partial.repelStrength == 3)
        #expect(partial.linkDistance == 250)

        let encoded = try JSONEncoder().encode(ObsidianGraphForces(linkDistance: 120))
        let keys = try JSONSerialization.jsonObject(with: encoded) as! [String: Double]
        #expect(keys == ["centerStrength": 0.518713248970312, "repelStrength": 10, "linkStrength": 1, "linkDistance": 120])
    }

    @Test func mapsTheSlidersToTheSimulation() {
        let c = ObsidianGraphForces.defaults.configuration
        #expect(abs(c.position.strength - 0.0518713248970312) < 1e-12)
        #expect(c.manyBody.strength == -100)
        #expect(c.link.strength == .degreeBased(scale: 1))
        #expect(c.link.distance == 62.5)
        // Everything the sliders don't control is the base configuration's.
        let base = ForceSimulationConfiguration(alphaDecay: 0.05, seed: 7)
        let mapped = ObsidianGraphForces.defaults.configuration(base: base)
        #expect(mapped.alphaDecay == 0.05 && mapped.seed == 7)
    }

    @Test func clampsToTheSliderRanges() {
        let wild = ObsidianGraphForces(centerStrength: -1, repelStrength: 99, linkStrength: .nan, linkDistance: 1)
        #expect(wild.clamped == ObsidianGraphForces(centerStrength: 0, repelStrength: 20, linkStrength: 1, linkDistance: 30))
        #expect(wild.configuration.manyBody.strength == -200)
        #expect(ObsidianGraphForces.linkDistanceRange == 30...500)
    }
}
