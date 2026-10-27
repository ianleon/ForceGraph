import ForceGraph

// The browser invokes this ABI synchronously from one JavaScript event loop. Mutable
// storage stays in this executable adapter; the library itself remains Sendable and pure.
private enum BrowserGraph {
    nonisolated(unsafe) static var simulation = ForceSimulation<Int>(nodes: [], edges: [])
    nonisolated(unsafe) static var nodes: [Int] = []
    nonisolated(unsafe) static var edges: [GraphEdge<Int>] = []
}

@_expose(wasm, "fg_reset")
@_cdecl("fg_reset")
public func resetGraph(_ nodeCount: Int32) {
    let count = min(max(Int(nodeCount), 0), 1_000)
    BrowserGraph.nodes = Array(0..<count)
    BrowserGraph.edges = []
    BrowserGraph.simulation = ForceSimulation(nodes: BrowserGraph.nodes, edges: [])
}

@_expose(wasm, "fg_add_edge")
@_cdecl("fg_add_edge")
public func addEdge(_ source: Int32, _ target: Int32) {
    guard BrowserGraph.edges.count < 10_000 else { return }
    BrowserGraph.edges.append(GraphEdge(Int(source), Int(target)))
}

@_expose(wasm, "fg_start")
@_cdecl("fg_start")
public func startGraph() {
    let configuration = BrowserGraph.simulation.configuration
    BrowserGraph.simulation = ForceSimulation(
        nodes: BrowserGraph.nodes,
        edges: BrowserGraph.edges,
        configuration: configuration
    )
}

@_expose(wasm, "fg_configure")
@_cdecl("fg_configure")
public func configureGraph(_ repulsion: Double, _ linkDistance: Double, _ centerStrength: Double) {
    var configuration = BrowserGraph.simulation.configuration
    configuration.manyBody.strength = -repulsion
    configuration.link.distance = linkDistance
    configuration.position.strength = centerStrength
    BrowserGraph.simulation.configuration = configuration
    BrowserGraph.simulation.reheat(to: 0.5)
}

@_expose(wasm, "fg_step")
@_cdecl("fg_step")
public func stepGraph() -> Int32 {
    BrowserGraph.simulation.step() ? 1 : 0
}

@_expose(wasm, "fg_x")
@_cdecl("fg_x")
public func nodeX(_ index: Int32) -> Double {
    guard let position = BrowserGraph.simulation.position(of: Int(index)) else { return 0 }
    return Double(position.x)
}

@_expose(wasm, "fg_y")
@_cdecl("fg_y")
public func nodeY(_ index: Int32) -> Double {
    guard let position = BrowserGraph.simulation.position(of: Int(index)) else { return 0 }
    return Double(position.y)
}

@_expose(wasm, "fg_begin_drag")
@_cdecl("fg_begin_drag")
public func beginDrag(_ index: Int32, _ x: Double, _ y: Double) {
    BrowserGraph.simulation.beginDrag(Int(index), at: .init(x: x, y: y))
}

@_expose(wasm, "fg_drag")
@_cdecl("fg_drag")
public func dragNode(_ index: Int32, _ x: Double, _ y: Double) {
    BrowserGraph.simulation.drag(Int(index), to: .init(x: x, y: y))
}

@_expose(wasm, "fg_end_drag")
@_cdecl("fg_end_drag")
public func endDrag(_ index: Int32) {
    BrowserGraph.simulation.endDrag(Int(index))
}

@_expose(wasm, "fg_reheat")
@_cdecl("fg_reheat")
public func reheatGraph() {
    BrowserGraph.simulation.reheat()
}

#if !os(WASI)
// A native reference fixture for the cross-runtime conformance check.
if CommandLine.arguments.contains("--reference") {
    resetGraph(4)
    addEdge(0, 1)
    addEdge(1, 2)
    addEdge(1, 3)
    startGraph()
    configureGraph(180, 75, 0.015)
    for _ in 0..<30 { _ = stepGraph() }
    let coordinates = (0..<4).flatMap { [nodeX($0), nodeY($0)] }
    print("[" + coordinates.map { String($0) }.joined(separator: ",") + "]")
}
#endif
