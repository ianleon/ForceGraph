#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import Testing
@testable import ForceGraph

@MainActor
@Suite struct LiveGraphControllerTests {
    private func makeController() -> LiveGraphController<String> {
        let controller = LiveGraphController<String>()
        controller.configure(nodes: ["a", "b"], edges: [GraphEdge("a", "b")], configuration: .init())
        return controller
    }

    @Test func newControllerHasNoEngineOrFrames() {
        let controller = LiveGraphController<String>()
        #expect(controller.positions.isEmpty)
        #expect(!controller.isRunning)
        controller.advance()
        controller.settle()
        controller.setRadius(12, for: "missing")
        controller.drag(to: .zero)
        controller.endDrag()
        #expect(controller.generation == 0)
    }

    @Test func configurationPublishesAndWakesAnimation() {
        let controller = makeController()
        #expect(Set(controller.positions.keys) == ["a", "b"])
        #expect(controller.isRunning)
        #expect(controller.generation == 1)
        controller.advance()
        #expect(controller.simulation?.tickCount == 1)
    }

    @Test func dragPreservesGrabOffsetAndReleases() {
        let controller = makeController()
        let initial = controller.positions["a"]!
        let pointer = CGPoint(x: initial.x + 4, y: initial.y - 6)
        controller.beginDrag("a", at: pointer)
        #expect(controller.draggedNode == "a")
        #expect(controller.positions["a"] == initial)
        controller.drag(to: CGPoint(x: pointer.x + 60, y: pointer.y + 40))
        #expect(controller.positions["a"] == CGPoint(x: initial.x + 60, y: initial.y + 40))
        controller.advance()
        #expect(controller.positions["a"] == CGPoint(x: initial.x + 60, y: initial.y + 40))
        controller.endDrag()
        #expect(controller.draggedNode == nil)
        #expect(controller.simulation?.fixedPosition(of: "a") == nil)
        #expect(controller.simulation?.alphaTarget == 0)
        #expect(controller.generation == 3)
    }

    @Test func neighboursReactWhileHeld() {
        let controller = makeController()
        let before = controller.positions["b"]!
        controller.beginDrag("a", at: controller.positions["a"]!)
        controller.drag(to: CGPoint(x: 300, y: 150))
        for _ in 0..<8 { controller.advance() }
        #expect(controller.positions["b"] != before)
        #expect(controller.positions["a"] == CGPoint(x: 300, y: 150))
    }

    @Test func invalidDragCannotAcquireOrMoveANode() {
        let controller = makeController()
        controller.beginDrag("missing", at: .zero)
        controller.beginDrag("a", at: CGPoint(x: CGFloat.nan, y: 0))
        controller.beginDrag("a", at: CGPoint(x: 0, y: CGFloat.infinity))
        #expect(controller.draggedNode == nil)
        controller.beginDrag("a", at: controller.positions["a"]!)
        let before = controller.positions
        controller.drag(to: CGPoint(x: CGFloat.infinity, y: 0))
        #expect(controller.positions == before)
    }

    @Test func secondDragReleasesThePreviousNode() {
        let controller = makeController()
        controller.beginDrag("a", at: .zero)
        controller.beginDrag("b", at: .zero)
        #expect(controller.draggedNode == "b")
        #expect(controller.simulation?.fixedPosition(of: "a") == nil)
        #expect(controller.simulation?.draggedNodes == ["b"])
    }

    @Test func reduceMotionSettlesAndDoesNotMoveHeldNode() {
        let controller = makeController()
        controller.settle()
        #expect(!controller.isRunning)
        let settled = controller.positions
        controller.advance()
        #expect(controller.positions == settled)
        controller.beginDrag("a", at: controller.positions["a"]!)
        let tick = controller.simulation?.tickCount
        controller.settle()
        #expect(controller.simulation?.tickCount == tick)
        controller.endDrag()
        controller.settle()
        #expect(!controller.isRunning)
    }

    @Test func graphUpdateKeepsSurvivorsAndClearsAnActiveDrag() {
        let controller = makeController()
        controller.beginDrag("a", at: .zero)
        controller.drag(to: CGPoint(x: 100, y: 100))
        let before = controller.positions["a"]
        var configuration = ForceSimulationConfiguration()
        configuration.link.distance = 90
        controller.configure(nodes: ["a", "c"], edges: [GraphEdge("a", "c")], configuration: configuration)
        #expect(controller.draggedNode == nil)
        #expect(controller.positions["a"] == before)
        #expect(controller.positions["b"] == nil)
        #expect(controller.positions["c"] != nil)
        #expect(controller.simulation?.configuration == configuration)
    }

    @Test func radiusOverrideAndClearAreApplied() {
        let controller = makeController()
        controller.setRadius(20, for: "a")
        #expect(controller.simulation?.radius(at: 0) == 20)
        controller.beginDrag("a", at: .zero)
        controller.clear()
        #expect(controller.positions.isEmpty)
        #expect(controller.simulation == nil)
        #expect(controller.draggedNode == nil)
        #expect(!controller.isRunning)
    }

    @Test func emptyGraphConfiguresAndSettlesSafely() {
        let controller = LiveGraphController<String>()
        controller.configure(nodes: [], edges: [], configuration: .init())
        controller.settle()
        #expect(controller.positions.isEmpty)
        #expect(!controller.isRunning)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteSpacingCannotCollapseViewport(distance: Double) {
        #expect(LiveGraphGeometry.spacing(for: distance) == 30)
    }

    @Test func finiteSpacingHasPositiveExtent() {
        #expect(LiveGraphGeometry.spacing(for: -5) == 1)
        #expect(LiveGraphGeometry.spacing(for: 0) == 1)
        #expect(LiveGraphGeometry.spacing(for: 75) == 75)
    }

    @Test func viewSimulationModifierIsOptInAndPreservesTapHandler() {
        var tapped: String?
        let fixed = ForceGraphView(nodes: ["a"], edges: []) { tapped = $0 }
        #expect(fixed.simulationConfiguration == nil)
        let live = fixed.simulation().nodeLabel { $0 }
        #expect(live.simulationConfiguration == ForceSimulationConfiguration())
        live.onTap("a")
        #expect(tapped == "a")
        #expect(live.customLabel("a") == "a")
    }
}
#endif
