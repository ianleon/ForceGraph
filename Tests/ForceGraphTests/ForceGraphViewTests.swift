#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI
import Testing
@testable import ForceGraph

/// Pins the view's call shapes. These compile in the package's Swift 6 language mode, where
/// an unlabeled trailing closure binds to the first closure parameter it can.
@MainActor
@Suite struct ForceGraphViewTests {
    @Test func trailingClosureIsTheTapHandler() {
        var tapped: String?
        let view = ForceGraphView(nodes: ["a", "b"], edges: [GraphEdge("a", "b")]) { tapped = $0 }
        view.onTap("b")
        #expect(tapped == "b")
    }

    @Test func modifiersSetPerNodeCustomization() {
        var tapped: Int?
        let view = ForceGraphView(nodes: [1, 2, 3], edges: [], fitTrigger: 0) { tapped = $0 }
            .nodeLabel { "Node \($0)" }
            .nodeColor { $0 == 2 ? .orange : nil }
            .nodeRadius { $0 == 3 ? 20 : nil }
        view.onTap(1)
        #expect(tapped == 1)
        #expect(view.customLabel(1) == "Node 1")
        #expect(view.customColor(2) == .orange)
        #expect(view.customColor(1) == nil)
        #expect(view.customRadius(3) == 20)
        #expect(view.customRadius(1) == nil)
    }

    @Test func viewWithoutClosuresHasNoCustomization() {
        let view = ForceGraphView<String>(nodes: ["a"], edges: [], style: ForceGraphStyle(minimumLabelSpacing: 24))
        #expect(view.customLabel("a") == nil)
        #expect(view.customColor("a") == nil)
        #expect(view.customRadius("a") == nil)
    }

    @Test func styleIsHashableWithMemberwiseDefaults() {
        #expect(ForceGraphStyle() == ForceGraphStyle(minimumLabelSpacing: 48))
        #expect(ForceGraphStyle(minimumLabelSpacing: 24) != ForceGraphStyle())
        #expect(Set([ForceGraphStyle(), ForceGraphStyle()]).count == 1)
    }
}
#endif
