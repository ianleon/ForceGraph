#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// Appearance of a ``ForceGraphView``.
public struct ForceGraphStyle: Equatable, Sendable {
    public var nodeColor: Color = .accentColor
    public var edgeColor: Color = Color.secondary.opacity(0.35)
    public var edgeWidth: CGFloat = 1
    public var labelFont: Font = .system(size: 9)
    public var labelColor: Color = .secondary
    /// Labels are drawn once the layout's typical node spacing (`sqrt(area / nodeCount)`
    /// layout units) spans at least this many points on screen; they clutter a zoomed-out graph.
    public var labelSpacing: CGFloat = 48
    /// How far the user can zoom out, as a multiple of the scale that fits the whole graph.
    public var minimumZoom: CGFloat = 0.5
    /// How far the user can zoom in, as a multiple of the scale that fits the whole graph.
    public var maximumZoom: CGFloat = 10
    /// Space kept between the graph and the view's edges when fitting.
    public var fitPadding: CGFloat = 32

    public init() {}
}

/// A pannable, zoomable force-directed graph drawn with `Canvas`.
///
/// The layout animates as it settles (``ForceLayout/stream(reportingEvery:minimumInterval:)``) and
/// is fitted to the view until the user pans or zooms. Double-tap fits it again.
/// Available on iOS, macOS and visionOS; ``ForceLayout`` itself builds everywhere.
///
/// ```swift
/// ForceGraphView(nodes: titles, edges: links, label: { $0 }) { tapped in
///     open(tapped)
/// }
/// ```
public struct ForceGraphView<ID: Hashable & Sendable>: View {
    private let nodes: [ID]
    private let edges: [GraphEdge<ID>]
    private let configuration: ForceLayoutConfiguration
    private let style: ForceGraphStyle
    private let radius: (ID) -> CGFloat
    private let nodeColor: ((ID) -> Color)?
    private let label: (ID) -> String?
    private let fitTrigger: AnyHashable?
    private let onTap: (ID) -> Void

    @State private var positions: [ID: CGPoint] = [:]
    @State private var laidOut: LayoutInput<ID>?
    @State private var viewSize: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var fittedScale: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @State private var panTranslation: CGSize = .zero
    @State private var zoomShift: CGSize = .zero
    @State private var autoFit = true

    /// - Parameters:
    ///   - radius: Node radius in points. Defaults to a size that grows with the node's degree (4…14 pt).
    ///   - nodeColor: Fill for a node, e.g. to highlight a selection. Defaults to `style.nodeColor`.
    ///   - label: Text drawn under a node, or nil for none.
    ///   - fitTrigger: Change this value to fit the graph to the view again, e.g. from a toolbar button.
    ///   - onTap: Called with the node under a tap.
    public init(
        nodes: [ID],
        edges: [GraphEdge<ID>],
        configuration: ForceLayoutConfiguration = .init(),
        style: ForceGraphStyle = .init(),
        radius: ((ID) -> CGFloat)? = nil,
        nodeColor: ((ID) -> Color)? = nil,
        label: @escaping (ID) -> String? = { _ in nil },
        fitTrigger: AnyHashable? = nil,
        onTap: @escaping (ID) -> Void = { _ in }
    ) {
        self.nodes = nodes
        self.edges = edges
        self.configuration = configuration
        self.style = style
        self.nodeColor = nodeColor
        self.label = label
        self.fitTrigger = fitTrigger
        self.onTap = onTap
        if let radius {
            self.radius = radius
        } else {
            let degrees = ForceLayout.degrees(nodes: nodes, edges: edges)
            self.radius = { id in min(4 + sqrt(CGFloat(degrees[id] ?? 0)) * 2, 14) }
        }
    }

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
                for edge in edges {
                    guard let from = positions[edge.source], let to = positions[edge.target] else { continue }
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

                let showLabels = typicalSpacing * scale >= style.labelSpacing
                for node in nodes {
                    guard let pos = positions[node] else { continue }
                    let screen = toScreen(pos)
                    guard visible.contains(screen) else { continue }
                    let r = radius(node)
                    let rect = CGRect(x: screen.x - r, y: screen.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(nodeColor?(node) ?? style.nodeColor))
                    if showLabels, let text = label(node) {
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
                    .onChanged { value in
                        autoFit = false
                        panTranslation = value.translation
                    }
                    .onEnded { value in
                        steadyOffset.width += value.translation.width
                        steadyOffset.height += value.translation.height
                        panTranslation = .zero
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
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
                    Button(label(node) ?? "\(node)") { onTap(node) }
                }
            }
            .accessibilityLabel("Graph with \(positions.count) nodes")
            .task(id: LayoutInput(nodes: nodes, edges: edges, configuration: configuration)) {
                let input = LayoutInput(nodes: nodes, edges: edges, configuration: configuration)
                // Reappearing with the same input keeps the settled layout instead of re-simulating.
                guard laidOut != input else { return }
                laidOut = nil
                positions = [:]
                autoFit = true
                let layout = ForceLayout(nodes: nodes, edges: edges, configuration: configuration)
                for await snapshot in layout.stream() {
                    positions = snapshot
                    if autoFit { fit(in: viewSize) }
                }
                if !Task.isCancelled { laidOut = input }
            }
            .onChange(of: geo.size, initial: true) { _, newSize in
                viewSize = newSize
                if autoFit { fit(in: newSize) }
            }
            .onChange(of: fitTrigger) { _, _ in refit() }
        }
    }

    // MARK: - Geometry

    /// Pan and zoom combined: where the layout origin sits relative to the view's center.
    private var offset: CGSize {
        CGSize(width: steadyOffset.width + panTranslation.width + zoomShift.width,
               height: steadyOffset.height + panTranslation.height + zoomShift.height)
    }

    /// The layout's characteristic node spacing, `sqrt(area / nodeCount)`, in layout units.
    private var typicalSpacing: CGFloat {
        (max(configuration.area, 0) / Double(max(positions.count, 1))).squareRoot()
    }

    private var uniqueNodes: [ID] {
        var seen = Set<ID>()
        return nodes.filter { seen.insert($0).inserted }
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
        guard !positions.isEmpty, size.width > 0, size.height > 0 else { return }
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var maxRadius: CGFloat = 0
        for (node, p) in positions {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            maxRadius = max(maxRadius, radius(node))
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
        for (node, pos) in positions {
            let d = hypot(pos.x - point.x, pos.y - point.y)
            // Reach is in points; convert to layout units at the current scale.
            let reach = max(radius(node) * 1.5, 22) / scale
            if d <= reach && d < (best?.1 ?? .infinity) {
                best = (node, d)
            }
        }
        return best?.0
    }
}

private struct LayoutInput<ID: Hashable & Sendable>: Equatable {
    var nodes: [ID]
    var edges: [GraphEdge<ID>]
    var configuration: ForceLayoutConfiguration
}
#endif
