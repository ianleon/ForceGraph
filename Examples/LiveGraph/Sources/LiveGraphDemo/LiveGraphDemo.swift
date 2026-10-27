import AppKit
import ForceGraph
import SwiftUI

/// A small host for the same public view Basalt uses. Run with `swift run` in this folder.
@main
struct LiveGraphDemoApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("ForceGraph Live Preview") {
            LiveGraphDemo()
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }
}

private struct LiveGraphDemo: View {
    @State private var repulsion = 180.0
    @State private var fitRequest = 0
    @State private var resetRequest = 0
    @State private var selected: String?
    private let graph = SampleGraph()

    private var configuration: ForceSimulationConfiguration {
        var configuration = ForceSimulationConfiguration()
        configuration.link.distance = 75
        configuration.manyBody.strength = -repulsion
        configuration.position.strength = 0.015
        return configuration
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("ForceGraph · Live simulation").font(.title2.bold())
                    Text("Drag nodes to move them; drag empty space to pan. Pinch to zoom.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fit") { fitRequest += 1 }
                Button("Reset") { resetRequest += 1 }
            }
            .padding(20)

            ForceGraphView(nodes: graph.nodes, edges: graph.edges, fitTrigger: fitRequest) {
                selected = $0
            }
            .simulation(configuration)
            .nodeLabel { $0 }
            .nodeColor { $0 == selected ? .orange : ($0.contains(" ") ? .cyan : .purple) }
            .id(resetRequest)

            HStack {
                Text("Repulsion")
                Slider(value: $repulsion, in: 30...650)
                Text(selected.map { "Selected: \($0)" } ?? "42 nodes · native SwiftUI Canvas")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}

private struct SampleGraph {
    let nodes: [String]
    let edges: [GraphEdge<String>]

    init() {
        let topics = ["Basalt", "Swift", "Projects", "Reading", "Ideas", "Daily"]
        var nodes = topics
        var edges: [GraphEdge<String>] = []
        for (index, topic) in topics.enumerated() {
            if index > 0 { edges.append(GraphEdge("Basalt", topic)) }
            for number in 1...6 {
                let title = "\(topic) \(number)"
                nodes.append(title)
                edges.append(GraphEdge(topic, title))
            }
        }
        self.nodes = nodes
        self.edges = edges
    }
}
