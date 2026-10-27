import Foundation
import Testing
import ForceGraph

@Suite struct ForceSimulationRegressionTests {
    @Test func dragReleaseKeepsTheLastPointerPositionWithoutATick() {
        var simulation = ForceSimulation(nodes: [1], edges: [])
        simulation.beginDrag(1, at: .zero)
        let destination = CGPoint(x: 80, y: -40)
        simulation.drag(1, to: destination)
        #expect(simulation.position(of: 1) == destination)
        simulation.endDrag(1)
        #expect(simulation.position(of: 1) == destination)
        #expect(simulation.fixedPosition(of: 1) == nil)
        #expect(simulation.velocity(of: 1)?.dx == 0)
        #expect(simulation.velocity(of: 1)?.dy == 0)
    }

    @Test func invalidDragPointsLeaveTheDragStateUntouched() {
        var simulation = ForceSimulation(nodes: [1], edges: [], alpha: 0)
        let original = simulation.snapshot()
        simulation.beginDrag(1, at: CGPoint(x: CGFloat.nan, y: 0))
        simulation.beginDrag(1, at: CGPoint(x: 0, y: CGFloat.infinity))
        #expect(simulation.draggedNodes.isEmpty)
        #expect(simulation.alphaTarget == 0)
        #expect(simulation.alpha == 0)
        #expect(simulation.snapshot() == original)
        simulation.beginDrag(1, at: .zero)
        simulation.drag(1, to: CGPoint(x: CGFloat.infinity, y: 0))
        #expect(simulation.position(of: 1) == .zero)
        #expect(simulation.fixedPosition(of: 1) == .zero)
    }

    @Test func updatesOnlyClearTheTargetWhenTheLastDragIsRemoved() {
        var simulation = ForceSimulation(nodes: [1, 2], edges: [])
        simulation.alphaTarget = simulation.configuration.dragAlphaTarget
        simulation.update(nodes: [1, 2], edges: [])
        #expect(simulation.alphaTarget == 0.3)
        simulation.beginDrag(1, at: .zero)
        simulation.beginDrag(2, at: .zero)
        simulation.configuration.dragAlphaTarget = 0.6
        simulation.remove(1)
        #expect(simulation.draggedNodes == [2])
        #expect(simulation.alphaTarget == 0.3)
        simulation.remove(2)
        #expect(simulation.draggedNodes.isEmpty)
        #expect(simulation.alphaTarget == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func malformedCoordinatesDisableTheirForce(value: Double) {
        var configuration = ForceSimulationConfiguration()
        configuration.position = .init(x: value, y: 0, strength: 1)
        configuration.center = .init(x: 0, y: value, strength: 1)
        var malformed = ForceSimulation(nodes: [1, 2], edges: [], configuration: configuration)
        configuration.position.strength = 0
        configuration.center.strength = 0
        var disabled = ForceSimulation(nodes: [1, 2], edges: [], configuration: configuration)
        malformed.tick(10)
        disabled.tick(10)
        #expect(malformed.snapshot() == disabled.snapshot())
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func malformedCollisionPaddingIsConsistentAfterRadiusOverrides(value: Double) {
        var configuration = ForceSimulationConfiguration()
        configuration.collision.padding = value
        var overridden = ForceSimulation(nodes: [1, 2], edges: [], configuration: configuration)
        var refreshed = overridden
        overridden.setRadius(20, for: 1)
        refreshed.setRadius(20, for: 1)
        refreshed.configuration = configuration
        overridden.tick(10)
        refreshed.tick(10)
        #expect(overridden.snapshot() == refreshed.snapshot())
        #expect(overridden.positions().allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func constantSpringStrengthRespectsItsDocumentedRange() {
        var configuration = ForceSimulationConfiguration()
        configuration.link.strength = .constant(10)
        var excessive = ForceSimulation(nodes: [1, 2], edges: [.init(1, 2)], configuration: configuration)
        configuration.link.strength = .constant(1)
        var clamped = ForceSimulation(nodes: [1, 2], edges: [.init(1, 2)], configuration: configuration)
        excessive.tick(10)
        clamped.tick(10)
        #expect(excessive.snapshot() == clamped.snapshot())
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func malformedTemperaturesRecoverWithoutPoisoningPositions(value: Double) {
        var configuration = ForceSimulationConfiguration(alphaMin: value, dragAlphaTarget: value)
        var simulation = ForceSimulation(nodes: [1, 2], edges: [], configuration: configuration)
        #expect(!simulation.isSettled)
        simulation.beginDrag(1, at: .zero)
        #expect(simulation.alphaTarget == 0.3)
        simulation.endDrag(1)
        simulation.alpha = value
        simulation.reheat(to: value)
        #expect(!simulation.alpha.isFinite)
        simulation.reheat(to: -1)
        #expect(!simulation.alpha.isFinite)
        simulation.reheat(to: 0.5)
        #expect(simulation.alpha == 0.5)
        simulation.alpha = value
        simulation.alphaTarget = value
        simulation.tick()
        #expect(simulation.alpha.isFinite)
        #expect(simulation.positions().allSatisfy { $0.x.isFinite && $0.y.isFinite })
        configuration.alphaMin = 0.001
        simulation.configuration = configuration
        simulation.alphaTarget = 0
        simulation.settle()
        #expect(simulation.isSettled)
    }

    @Test func pinAndRadiusSurviveReorderingButNotRemoval() {
        var simulation = ForceSimulation(nodes: [1, 2], edges: [])
        let pin = CGPoint(x: 15, y: 30)
        simulation.fix(1, at: pin)
        simulation.setRadius(12, for: 1)
        simulation.update(nodes: [2, 1], edges: [])
        #expect(simulation.fixedPosition(of: 1) == pin)
        #expect(simulation.radius(at: 1) == 12)
        simulation.remove(1)
        simulation.add(1)
        #expect(simulation.fixedPosition(of: 1) == nil)
        #expect(simulation.radius(at: 1) == 4)
    }
}
