#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// Appearance of a ``ForceGraphView``.
///
/// Change a single property inline with the memberwise initializer:
///
/// ```swift
/// ForceGraphView(nodes: titles, edges: links, style: ForceGraphStyle(minimumLabelSpacing: 24))
/// ```
public struct ForceGraphStyle: Hashable, Sendable {
    /// Fill for nodes that ``ForceGraphView/nodeColor(_:)`` does not colour.
    public var nodeColor: Color
    /// Stroke colour for edges.
    public var edgeColor: Color
    /// Stroke width for edges, in points.
    public var edgeWidth: CGFloat
    /// Font for node labels.
    public var labelFont: Font
    /// Colour for node labels.
    public var labelColor: Color
    /// Labels are drawn once the layout's typical node spacing (`sqrt(area / nodeCount)`
    /// layout units) spans at least this many points on screen; they clutter a zoomed-out
    /// graph. Lower it to show labels sooner on dense graphs.
    public var minimumLabelSpacing: CGFloat
    /// How far the user can zoom out, as a multiple of the scale that fits the whole graph.
    public var minimumZoom: CGFloat
    /// How far the user can zoom in, as a multiple of the scale that fits the whole graph.
    public var maximumZoom: CGFloat
    /// Space kept between the graph and the view's edges when fitting, in points.
    public var fitPadding: CGFloat

    /// Creates a style. Every parameter defaults to the standard appearance (accent-coloured
    /// nodes, faint edges and 9 pt secondary labels), so pass only what you want to change.
    public init(
        nodeColor: Color = .accentColor,
        edgeColor: Color = Color.secondary.opacity(0.35),
        edgeWidth: CGFloat = 1,
        labelFont: Font = .system(size: 9),
        labelColor: Color = .secondary,
        minimumLabelSpacing: CGFloat = 48,
        minimumZoom: CGFloat = 0.5,
        maximumZoom: CGFloat = 10,
        fitPadding: CGFloat = 32
    ) {
        self.nodeColor = nodeColor
        self.edgeColor = edgeColor
        self.edgeWidth = edgeWidth
        self.labelFont = labelFont
        self.labelColor = labelColor
        self.minimumLabelSpacing = minimumLabelSpacing
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.fitPadding = fitPadding
    }
}

/// A pannable, zoomable force-directed graph drawn with `Canvas`.
///
/// The layout animates as it settles (``ForceLayout/stream(reportingEvery:minimumInterval:)``) and
/// is fitted to the view until the user pans or zooms. Double-tap fits it again.
/// Available on iOS, macOS and visionOS; ``ForceLayout`` itself has no UI dependency.
///
/// ```swift
/// ForceGraphView(nodes: titles, edges: links) { tapped in
///     open(tapped)
/// }
/// .nodeLabel { $0 }
/// .nodeColor { $0 == selected ? .orange : nil }
/// ```
///
/// When `nodes` or `edges` change, the view keeps the current positions and lets the
/// layout absorb the change from there (a warm start, see ``ForceLayout/initialPositions``)
/// instead of starting over. Changing `configuration` lays the graph out from scratch, and
/// so does giving the view a new identity with `.id(_:)`.
///
/// Each node is an accessibility element named by its ``nodeLabel(_:)`` text, or by its
/// identifier's description when it has none; activating it calls `onTap`. The view also
/// offers a "Fit to view" accessibility action. The view's accessibility strings are
/// looked up in the app's main bundle, so an app can translate them in its own string catalog.
public struct ForceGraphView<ID: Hashable & Sendable>: View {
    private let nodes: [ID]
    private let edges: [GraphEdge<ID>]
    private let configuration: ForceLayoutConfiguration
    private let style: ForceGraphStyle
    private let fitTrigger: AnyHashable?
    var simulationConfiguration: ForceSimulationConfiguration?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var live = LiveGraphController<ID>()
    @State private var dragStarted = false
    @State private var draggingNode = false
    @GestureState private var dragGestureActive = false
    @GestureState private var magnificationActive = false
    @State private var suppressDragUntilEnd = false
    // Internal rather than private so tests can check what the initializer and modifiers store.
    let onTap: (ID) -> Void
    var customRadius: (ID) -> CGFloat? = { _ in nil }
    var customColor: (ID) -> Color? = { _ in nil }
    var customLabel: (ID) -> String? = { _ in nil }

    @State private var positions: [ID: CGPoint] = [:]
    /// The input whose layout has fully settled, so reappearing does not re-simulate.
    @State private var settled: ForceLayout<ID>?
    /// The configuration the current positions were produced with.
    @State private var positionsConfiguration: ForceLayoutConfiguration?
    /// What is drawn: the layout's de-duplicated edges and the degrees that size nodes.
    @State private var drawnEdges: [GraphEdge<ID>] = []
    @State private var degrees: [ID: Int] = [:]
    @State private var viewSize: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var fittedScale: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @State private var panTranslation: CGSize = .zero
    @State private var zoomShift: CGSize = .zero
    @State private var autoFit = true

    /// Creates a graph view that lays out `nodes` and `edges` and draws them.
    ///
    /// Customize individual nodes with ``nodeLabel(_:)``, ``nodeColor(_:)`` and ``nodeRadius(_:)``.
    ///
    /// - Parameters:
    ///   - nodes: Node identifiers, in a stable order (node order seeds the layout).
    ///   - edges: Undirected edges between those identifiers. Self-loops, duplicate or
    ///     reversed pairs and edges to unknown nodes are ignored.
    ///   - configuration: Simulation tuning (iterations, area, gravity, seed).
    ///   - style: Colours, label font, zoom limits and fit padding.
    ///   - fitTrigger: Change this value to fit the graph to the view again, e.g. from a toolbar button.
    ///   - onTap: Called with the node under a tap. Usually written as a trailing closure.
    public init(
        nodes: [ID],
        edges: [GraphEdge<ID>],
        configuration: ForceLayoutConfiguration = .init(),
        style: ForceGraphStyle = .init(),
        fitTrigger: AnyHashable? = nil,
        onTap: @escaping (ID) -> Void = { _ in }
    ) {
        self.nodes = nodes
        self.edges = edges
        self.configuration = configuration
        self.style = style
        self.fitTrigger = fitTrigger
        self.onTap = onTap
    }

    // MARK: - Per-node customization

    /// Sets the text drawn under each node, or nil for no label.
    ///
    /// The text is also the node's VoiceOver name; nodes without one fall back to their
    /// identifier's description. Labels appear once nodes are far enough apart on screen
    /// (``ForceGraphStyle/minimumLabelSpacing``). Apply this directly to the
    /// `ForceGraphView`, before other view modifiers.
    public func nodeLabel(_ label: @escaping (ID) -> String?) -> Self {
        var copy = self
        copy.customLabel = label
        return copy
    }

    /// Sets the fill of individual nodes, e.g. to highlight a selection or a category.
    /// Return nil to use ``ForceGraphStyle/nodeColor``.
    ///
    /// Apply this directly to the `ForceGraphView`, before other view modifiers.
    public func nodeColor(_ color: @escaping (ID) -> Color?) -> Self {
        var copy = self
        copy.customColor = color
        return copy
    }

    /// Sets the radius of individual nodes, in points. Return nil to use the default,
    /// which grows with the node's degree from 4 to 14 points.
    ///
    /// Apply this directly to the `ForceGraphView`, before other view modifiers.
    public func nodeRadius(_ radius: @escaping (ID) -> CGFloat?) -> Self {
        var copy = self
        copy.customRadius = radius
        return copy
    }

    /// Enables a live simulation with node dragging. Drag empty space to pan; dragging a
    /// node holds it under the pointer and lets its neighbours respond. Releasing lets the
    /// graph cool to rest. The existing fixed-layout initializer remains unchanged.
    ///
    /// Apply before general SwiftUI view modifiers, like ``nodeLabel(_:)``.
    public func simulation(_ configuration: ForceSimulationConfiguration = .init()) -> Self {
        var copy = self
        copy.simulationConfiguration = configuration
        return copy
    }

    private var displayedPositions: [ID: CGPoint] {
        simulationConfiguration == nil ? positions : live.positions
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let center = viewCenter(in: size)
                let scale = scale
                let toScreen = { (p: CGPoint) -> CGPoint in
                    CGPoint(x: p.x * scale + center.x, y: p.y * scale + center.y)
                }
                // Skip what cannot be seen; the margin covers node radii and label overhang.
                let visible = CGRect(origin: .zero, size: size).insetBy(dx: -120, dy: -120)

                var edgePath = Path()
                for edge in drawnEdges {
                    guard let from = displayedPositions[edge.source], let to = displayedPositions[edge.target] else { continue }
                    let a = toScreen(from), b = toScreen(to)
                    // A segment entirely to one side of the view cannot cross it.
                    if (a.x < visible.minX && b.x < visible.minX) || (a.x > visible.maxX && b.x > visible.maxX)
                        || (a.y < visible.minY && b.y < visible.minY) || (a.y > visible.maxY && b.y > visible.maxY) {
                        continue
                    }
                    edgePath.move(to: a)
                    edgePath.addLine(to: b)
                }
                context.stroke(edgePath, with: .color(style.edgeColor), lineWidth: style.edgeWidth)

                let showLabels = typicalSpacing * scale >= style.minimumLabelSpacing
                for node in uniqueNodes {
                    guard let pos = displayedPositions[node] else { continue }
                    let screen = toScreen(pos)
                    guard visible.contains(screen) else { continue }
                    let r = radius(of: node)
                    let rect = CGRect(x: screen.x - r, y: screen.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(node == live.draggedNode ? .orange : (customColor(node) ?? style.nodeColor)))
                    if showLabels, let text = customLabel(node) {
                        context.draw(
                            Text(text).font(style.labelFont).foregroundStyle(style.labelColor),
                            at: CGPoint(x: screen.x, y: screen.y + r + 7)
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { refit() }
            .onTapGesture { location in
                let center = viewCenter(in: viewSize)
                let world = CGPoint(x: (location.x - center.x) / scale, y: (location.y - center.y) / scale)
                if let hit = nearestNode(to: world) {
                    onTap(hit)
                }
            }
            .gesture(
                DragGesture()
                    .updating($dragGestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard !magnificationActive, !suppressDragUntilEnd else { return }
                        autoFit = false
                        let start = worldPoint(value.startLocation)
                        if !dragStarted {
                            dragStarted = true
                            if simulationConfiguration != nil, let node = nearestNode(to: start) {
                                draggingNode = true
                                live.beginDrag(node, at: start)
                            }
                        }
                        if draggingNode {
                            live.drag(to: worldPoint(value.location))
                        } else {
                            panTranslation = value.translation
                        }
                    }
                    .onEnded { value in
                        guard dragStarted else { return }
                        if draggingNode {
                            live.drag(to: worldPoint(value.location))
                            live.endDrag()
                            if reduceMotion { live.settle() }
                        } else {
                            steadyOffset.width += value.translation.width
                            steadyOffset.height += value.translation.height
                        }
                        dragStarted = false
                        draggingNode = false
                        panTranslation = .zero
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnificationActive) { _, active, _ in active = true }
                    .onChanged { value in
                        suppressDragUntilEnd = true
                        finishInterruptedDrag()
                        autoFit = false
                        zoom(to: steadyScale * value.magnification, anchoredAt: value.startLocation, in: viewSize)
                    }
                    .onEnded { _ in
                        steadyScale = scale
                        steadyOffset.width += zoomShift.width
                        steadyOffset.height += zoomShift.height
                        zoomShift = .zero
                    }
            )
            .accessibilityChildren {
                ForEach(uniqueNodes, id: \.self) { node in
                    Button(customLabel(node) ?? String(describing: node)) { onTap(node) }
                }
            }
            .accessibilityLabel(Text("Graph with \(displayedPositions.count) nodes"))
            .accessibilityAction(named: Text("Fit to view")) { refit() }
            .task(id: GraphViewInput(nodes: nodes, edges: edges, layout: configuration,
                                     simulation: simulationConfiguration)) {
                finishInterruptedDrag()
                let input = ForceLayout(nodes: nodes, edges: edges, configuration: configuration)
                if let simulationConfiguration {
                    drawnEdges = input.uniqueEdges
                    degrees = input.degrees
                    let firstLayout = live.positions.isEmpty
                    live.configure(nodes: nodes, edges: edges, configuration: simulationConfiguration)
                    for node in uniqueNodes {
                        live.setRadius(Double(radius(of: node)), for: node)
                    }
                    if reduceMotion { live.settle() }
                    if firstLayout { autoFit = true }
                    if autoFit { fit(in: viewSize) }
                } else {
                    live.clear()
                    await layOut(input)
                }
            }
            .task(id: LiveAnimationInput(generation: live.generation, reduceMotion: reduceMotion)) {
                await animateLiveGraph()
            }
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { live.settle() }
            }
            .onChange(of: dragGestureActive) { _, active in
                if !active {
                    finishInterruptedDrag()
                    suppressDragUntilEnd = false
                }
            }
            .onChange(of: magnificationActive) { _, active in
                if !active, !dragGestureActive { suppressDragUntilEnd = false }
            }
            .onDisappear { finishInterruptedDrag() }
            .onChange(of: geo.size, initial: true) { _, newSize in
                viewSize = newSize
                if autoFit { fit(in: newSize) }
            }
            .onChange(of: fitTrigger) { _, _ in refit() }
        }
    }

    // MARK: - Layout

    /// Animates the layout of `input`, warm-starting from the current positions when only
    /// the nodes or edges changed.
    private func layOut(_ input: ForceLayout<ID>) async {
        // Reappearing with the same input keeps the settled layout instead of re-simulating.
        guard settled != input else { return }
        settled = nil
        drawnEdges = input.uniqueEdges
        degrees = input.degrees

        var layout = input
        if positionsConfiguration == input.configuration {
            let present = Set(input.nodes)
            positions = positions.filter { present.contains($0.key) }
            layout.initialPositions = positions
        } else {
            positions = [:]
        }
        positionsConfiguration = input.configuration
        // A fresh layout is fitted while it animates; a warm start keeps the user's viewport.
        if positions.isEmpty { autoFit = true }

        for await snapshot in layout.stream() {
            positions = snapshot
            if autoFit { fit(in: viewSize) }
        }
        if !Task.isCancelled { settled = input }
    }

    /// A settled graph suspends until input changes or a new drag wakes its generation.
    private func animateLiveGraph() async {
        guard simulationConfiguration != nil else { return }
        if reduceMotion {
            live.settle()
            if autoFit { fit(in: viewSize) }
            return
        }
        while !Task.isCancelled, live.isRunning {
            live.advance()
            if autoFit { fit(in: viewSize) }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
        }
    }

    /// GestureState resets on cancellation too, unlike DragGesture.onEnded.
    private func finishInterruptedDrag() {
        guard dragStarted else { return }
        if draggingNode {
            live.endDrag()
            if reduceMotion { live.settle() }
        } else {
            steadyOffset.width += panTranslation.width
            steadyOffset.height += panTranslation.height
        }
        dragStarted = false
        draggingNode = false
        panTranslation = .zero
    }

    private func worldPoint(_ screen: CGPoint) -> CGPoint {
        let center = viewCenter(in: viewSize)
        return CGPoint(x: (screen.x - center.x) / scale, y: (screen.y - center.y) / scale)
    }

    // MARK: - Geometry

    /// Pan and zoom combined: where the layout origin sits relative to the view's center.
    private var offset: CGSize {
        CGSize(width: steadyOffset.width + panTranslation.width + zoomShift.width,
               height: steadyOffset.height + panTranslation.height + zoomShift.height)
    }

    /// The layout's characteristic node spacing, `sqrt(area / nodeCount)`, in layout units.
    private var typicalSpacing: CGFloat {
        if let simulationConfiguration {
            return LiveGraphGeometry.spacing(for: simulationConfiguration.link.distance)
        }
        return (max(configuration.area, 0) / Double(max(positions.count, 1))).squareRoot()
    }

    private var uniqueNodes: [ID] {
        var seen = Set<ID>()
        return nodes.filter { seen.insert($0).inserted }
    }

    /// The node's radius in points: the custom one, or one that grows with degree (4…14 pt).
    private func radius(of node: ID) -> CGFloat {
        customRadius(node) ?? min(4 + sqrt(CGFloat(degrees[node] ?? 0)) * 2, 14)
    }

    private func viewCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
    }

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, fittedScale * style.minimumZoom), fittedScale * style.maximumZoom)
    }

    /// Changes the scale while keeping the layout point under `anchor` fixed on screen.
    private func zoom(to newScale: CGFloat, anchoredAt anchor: CGPoint, in size: CGSize) {
        let base = CGPoint(x: size.width / 2 + steadyOffset.width + panTranslation.width,
                           y: size.height / 2 + steadyOffset.height + panTranslation.height)
        let world = CGPoint(x: (anchor.x - base.x) / steadyScale, y: (anchor.y - base.y) / steadyScale)
        scale = clampScale(newScale)
        zoomShift = CGSize(width: anchor.x - base.x - world.x * scale,
                           height: anchor.y - base.y - world.y * scale)
    }

    private func refit() {
        autoFit = true
        fit(in: viewSize)
    }

    /// Chooses scale and offset so every node (plus padding) is visible.
    private func fit(in size: CGSize) {
        guard !displayedPositions.isEmpty, size.width > 0, size.height > 0 else { return }
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var maxRadius: CGFloat = 0
        for (node, p) in displayedPositions {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            maxRadius = max(maxRadius, radius(of: node))
        }
        // A lone node or a tight cluster is given at least one spacing unit of extent.
        let width = max(maxX - minX, typicalSpacing)
        let height = max(maxY - minY, typicalSpacing)
        // Radii are in points, so they join the padding rather than the layout bounds.
        let inset = style.fitPadding + maxRadius
        let available = CGSize(width: max(size.width - inset * 2, 1),
                               height: max(size.height - inset * 2, 1))
        fittedScale = min(available.width / width, available.height / height)
        scale = fittedScale
        steadyScale = fittedScale
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        steadyOffset = CGSize(width: -center.x * scale, height: -center.y * scale)
        panTranslation = .zero
        zoomShift = .zero
    }

    private func nearestNode(to point: CGPoint) -> ID? {
        var best: (ID, CGFloat)?
        for node in uniqueNodes {
            guard let pos = displayedPositions[node] else { continue }
            let d = hypot(pos.x - point.x, pos.y - point.y)
            // Reach is in points; convert to layout units at the current scale.
            let reach = max(radius(of: node) * 1.5, 22) / scale
            if d <= reach && d < (best?.1 ?? .infinity) {
                best = (node, d)
            }
        }
        return best?.0
    }
}
/// All inputs affecting the selected engine; presentation changes do not restart it.
private struct LiveAnimationInput: Hashable {
    let generation: Int
    let reduceMotion: Bool
}

private struct GraphViewInput<ID: Hashable & Sendable>: Hashable {
    let nodes: [ID]
    let edges: [GraphEdge<ID>]
    let layout: ForceLayoutConfiguration
    let simulation: ForceSimulationConfiguration?
}
#endif
