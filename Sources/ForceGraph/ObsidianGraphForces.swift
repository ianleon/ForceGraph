import Foundation

/// The four sliders in the Forces section of Obsidian's graph view, and how they map to a
/// ``ForceSimulationConfiguration``.
///
/// The property names, ranges and defaults are the ones Obsidian stores in a vault's
/// `.obsidian/graph.json`, so the type decodes straight from that file (other keys are
/// ignored, missing ones take their default) and encodes back to the same keys:
///
/// ```swift
/// let data = try Data(contentsOf: vault.appending(path: ".obsidian/graph.json"))
/// let forces = try JSONDecoder().decode(ObsidianGraphForces.self, from: data)
/// var simulation = ForceSimulation(nodes: notes, edges: links,
///                                  configuration: forces.configuration)
/// ```
///
/// | Slider        | Key              | Range    | Default | Maps to                                   |
/// |---------------|------------------|----------|---------|-------------------------------------------|
/// | Center force  | `centerStrength` | 0…1      | 0.5187  | position strength = value × 0.1            |
/// | Repel force   | `repelStrength`  | 0…20     | 10      | many-body strength = −value × 10           |
/// | Link force    | `linkStrength`   | 0…1      | 1       | link strength = value / min(degrees)       |
/// | Link distance | `linkDistance`   | 30…500   | 250     | link distance = value × 0.25 layout units  |
///
/// Obsidian's own engine is not public, so the scale factors are ForceGraph's: they are
/// chosen so the defaults give a readable layout at ``ForceGraphView``'s node sizes (a
/// layout unit is a point at zoom 1), with each slider moving the layout the way Obsidian's
/// does: more center force makes the graph rounder and pulls orphans in, more repel force
/// spreads it, less link force loosens links, more link distance lengthens them.
/// See <doc:LiveSimulation>.
public struct ObsidianGraphForces: Hashable, Sendable, Codable {
    /// "Center force": how compact the graph is, 0…1.
    public var centerStrength: Double
    /// "Repel force": how much each node pushes the others away, 0…20.
    public var repelStrength: Double
    /// "Link force": how tight each link is, 0…1.
    public var linkStrength: Double
    /// "Link distance": how long links are, 30…500.
    public var linkDistance: Double

    /// The slider ranges.
    public static let centerStrengthRange: ClosedRange<Double> = 0...1
    public static let repelStrengthRange: ClosedRange<Double> = 0...20
    public static let linkStrengthRange: ClosedRange<Double> = 0...1
    public static let linkDistanceRange: ClosedRange<Double> = 30...500

    /// Obsidian's defaults: center 0.518713248970312, repel 10, link force 1, distance 250.
    public static let defaults = ObsidianGraphForces()

    /// The scale factors of the mapping, documented in the table above.
    public static let centerScale = 0.1
    public static let repelScale = 10.0
    public static let distanceScale = 0.25

    /// Creates slider values; every parameter defaults to Obsidian's default.
    public init(
        centerStrength: Double = 0.518713248970312,
        repelStrength: Double = 10,
        linkStrength: Double = 1,
        linkDistance: Double = 250
    ) {
        self.centerStrength = centerStrength
        self.repelStrength = repelStrength
        self.linkStrength = linkStrength
        self.linkDistance = linkDistance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = ObsidianGraphForces.defaults
        centerStrength = try container.decodeIfPresent(Double.self, forKey: .centerStrength) ?? d.centerStrength
        repelStrength = try container.decodeIfPresent(Double.self, forKey: .repelStrength) ?? d.repelStrength
        linkStrength = try container.decodeIfPresent(Double.self, forKey: .linkStrength) ?? d.linkStrength
        linkDistance = try container.decodeIfPresent(Double.self, forKey: .linkDistance) ?? d.linkDistance
    }

    /// The values clamped to the slider ranges, with non-finite values replaced by defaults.
    public var clamped: ObsidianGraphForces {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        let d = ObsidianGraphForces.defaults
        return ObsidianGraphForces(
            centerStrength: clamp(centerStrength, Self.centerStrengthRange, d.centerStrength),
            repelStrength: clamp(repelStrength, Self.repelStrengthRange, d.repelStrength),
            linkStrength: clamp(linkStrength, Self.linkStrengthRange, d.linkStrength),
            linkDistance: clamp(linkDistance, Self.linkDistanceRange, d.linkDistance)
        )
    }

    /// The simulation configuration for these sliders (clamped to their ranges), on top of
    /// `base` for everything the sliders don't control.
    public func configuration(base: ForceSimulationConfiguration = .init()) -> ForceSimulationConfiguration {
        let v = clamped
        var c = base
        c.position.strength = v.centerStrength * Self.centerScale
        c.manyBody.strength = -v.repelStrength * Self.repelScale
        c.link.strength = .degreeBased(scale: v.linkStrength)
        c.link.distance = v.linkDistance * Self.distanceScale
        return c
    }

    /// The simulation configuration for these sliders, with the defaults for the rest.
    public var configuration: ForceSimulationConfiguration { configuration() }

    /// Writes the four keys as `graph.json` does. Merge them into the existing file rather
    /// than replacing it, so Obsidian's other graph settings survive.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(centerStrength, forKey: .centerStrength)
        try container.encode(repelStrength, forKey: .repelStrength)
        try container.encode(linkStrength, forKey: .linkStrength)
        try container.encode(linkDistance, forKey: .linkDistance)
    }

    private enum CodingKeys: String, CodingKey {
        case centerStrength, repelStrength, linkStrength, linkDistance
    }
}
