#if os(iOS) || os(macOS) || os(visionOS)
import Foundation
import Observation

/// Owns the live engine independently of SwiftUI's view lifetime and gestures.
/// A generation change wakes the view's animation task; settled graphs need no timer.
@MainActor
@Observable
final class LiveGraphController<ID: Hashable & Sendable> {
    private(set) var positions: [ID: CGPoint] = [:]
    private(set) var generation = 0
    private(set) var draggedNode: ID?
    private(set) var simulation: ForceSimulation<ID>?
    private var grabOffset = CGSize.zero

    var isRunning: Bool { simulation.map { !$0.isSettled } ?? false }

    func configure(nodes: [ID], edges: [GraphEdge<ID>], configuration: ForceSimulationConfiguration) {
        endDrag()
        if simulation == nil {
            simulation = ForceSimulation(nodes: nodes, edges: edges, configuration: configuration)
        } else {
            simulation?.configuration = configuration
            simulation?.update(nodes: nodes, edges: edges)
        }
        publishPositions()
        generation += 1
    }

    func setRadius(_ radius: Double?, for node: ID) {
        simulation?.setRadius(radius, for: node)
    }

    func advance() {
        guard isRunning else { return }
        simulation?.step()
        publishPositions()
    }

    /// Reduce Motion uses bounded settling instead of animating neighbours under a drag.
    func settle() {
        guard draggedNode == nil else { return }
        simulation?.settle()
        publishPositions()
    }

    func beginDrag(_ node: ID, at pointer: CGPoint) {
        guard pointer.x.isFinite, pointer.y.isFinite,
              let position = simulation?.position(of: node) else { return }
        endDrag()
        draggedNode = node
        grabOffset = CGSize(width: position.x - pointer.x, height: position.y - pointer.y)
        simulation?.beginDrag(node, at: position)
        generation += 1
    }

    func drag(to pointer: CGPoint) {
        guard let draggedNode else { return }
        let destination = CGPoint(x: pointer.x + grabOffset.width, y: pointer.y + grabOffset.height)
        simulation?.drag(draggedNode, to: destination)
        publishPositions()
    }

    func endDrag() {
        guard let draggedNode else { return }
        simulation?.endDrag(draggedNode)
        self.draggedNode = nil
        grabOffset = .zero
        publishPositions()
        generation += 1
    }

    /// Reset when returning to the original fixed-layout presentation.
    func clear() {
        endDrag()
        simulation = nil
        positions = [:]
        generation += 1
    }

    private func publishPositions() {
        positions = simulation?.snapshot() ?? [:]
    }
}
/// Normalizes public force distances before they become viewport divisors.
enum LiveGraphGeometry {
    static func spacing(for distance: Double) -> CGFloat {
        guard distance.isFinite else { return 30 }
        return max(distance, 1)
    }
}
#endif
