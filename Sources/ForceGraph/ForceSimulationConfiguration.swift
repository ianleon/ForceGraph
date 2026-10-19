import Foundation

/// Tuning for ``ForceSimulation``: the cooling schedule, the friction, and the forces.
///
/// The parameters and their defaults follow d3-force: `alpha` starts at 1 and decays toward
/// ``ForceSimulation/alphaTarget`` by ``alphaDecay`` each tick, the simulation comes to
/// rest when it falls below ``alphaMin`` (after 300 ticks with the defaults), and each tick
/// keeps `1 - velocityDecay` of every node's velocity. The forces are applied in a fixed
/// order: link, many-body, position, collision, then center.
///
/// The defaults are d3-force's own defaults for each force, plus a weak pull toward the
/// origin (``PositionForce``) so disconnected parts stay together, and a collision force
/// sized to ``ForceGraphView``'s default node radii. For the settings of Obsidian's graph
/// view, use ``ObsidianGraphForces/configuration``.
///
/// Out-of-range values are clamped rather than rejected when the simulation uses them.
public struct ForceSimulationConfiguration: Hashable, Sendable {
    /// The simulation stops when ``ForceSimulation/alpha`` falls below this. Default 0.001.
    public var alphaMin: Double
    /// How quickly alpha approaches its target each tick, 0…1. The default,
    /// `1 - pow(0.001, 1 / 300)` ≈ 0.0228, cools from 1 to ``alphaMin`` in 300 ticks; higher
    /// values settle sooner and less well.
    public var alphaDecay: Double
    /// The fraction of each node's velocity lost every tick, 0…1, like friction. Default 0.4.
    public var velocityDecay: Double
    /// The ``ForceSimulation/alphaTarget`` used while a node is dragged with
    /// ``ForceSimulation/beginDrag(_:at:)``, which keeps the graph moving under the finger.
    /// Default 0.3, as in d3-force's drag examples.
    public var dragAlphaTarget: Double
    /// The springs along links.
    public var link: LinkForce
    /// Repulsion (or attraction) between every pair of nodes, approximated with Barnes–Hut.
    public var manyBody: ManyBodyForce
    /// A pull toward a point, proportional to distance (d3's `forceX` and `forceY`).
    public var position: PositionForce
    /// Keeps nodes from overlapping.
    public var collision: CollisionForce
    /// Translates the whole graph so its mean position is at a point (d3's `forceCenter`).
    public var center: CenterForce
    /// Seed for the random jitter that separates coincident nodes. The same seed, graph,
    /// starting positions and sequence of calls always produce the same positions.
    public var seed: UInt64

    /// Creates a configuration. Every parameter has a default, so pass only what you change.
    public init(
        alphaMin: Double = 0.001,
        alphaDecay: Double = 1 - pow(0.001, 1.0 / 300),
        velocityDecay: Double = 0.4,
        dragAlphaTarget: Double = 0.3,
        link: LinkForce = LinkForce(),
        manyBody: ManyBodyForce = ManyBodyForce(),
        position: PositionForce = PositionForce(),
        collision: CollisionForce = CollisionForce(),
        center: CenterForce = CenterForce(),
        seed: UInt64 = 0x5EED
    ) {
        self.alphaMin = alphaMin
        self.alphaDecay = alphaDecay
        self.velocityDecay = velocityDecay
        self.dragAlphaTarget = dragAlphaTarget
        self.link = link
        self.manyBody = manyBody
        self.position = position
        self.collision = collision
        self.center = center
        self.seed = seed
    }
}

extension ForceSimulationConfiguration {
    /// Springs that pull linked nodes toward ``distance`` apart (d3's `forceLink`).
    ///
    /// Each tick, every link nudges the velocities of its two ends by
    /// `(length - distance) / length × alpha × strength` of the vector between them, split
    /// between the ends by their degrees so a hub moves less than a leaf (d3's bias).
    public struct LinkForce: Hashable, Sendable {
        /// The rest length of a link, in layout units. Default 30.
        public var distance: Double
        /// How stiff the springs are.
        public var strength: Strength
        /// How many times the springs are applied per tick. More iterations make the links
        /// stiffer and cost more. Default 1.
        public var iterations: Int

        /// How stiff a link's spring is.
        public enum Strength: Hashable, Sendable {
            /// d3-force's default, `scale / min(degree(source), degree(target))`: links to a
            /// hub are weaker, which keeps hubs from collapsing their neighbourhood. Scale
            /// 1 is d3's default.
            case degreeBased(scale: Double)
            /// The same strength, 0…1 for stability, for every link.
            case constant(Double)
        }

        /// Creates a link force; the defaults are d3-force's.
        public init(distance: Double = 30, strength: Strength = .degreeBased(scale: 1), iterations: Int = 1) {
            self.distance = distance
            self.strength = strength
            self.iterations = iterations
        }
    }

    /// Repulsion between every pair of nodes, like charged particles (d3's `forceManyBody`).
    ///
    /// A node at distance `d` changes another's velocity by `strength × alpha / d`, pointing
    /// away when `strength` is negative. The sum over all pairs is approximated with a
    /// Barnes–Hut quadtree, O(n log n) per tick: a cell whose width `w` satisfies
    /// `w / d < theta` acts as one body at its centre of strength.
    public struct ManyBodyForce: Hashable, Sendable {
        /// Negative repels, positive attracts. Default −30.
        public var strength: Double
        /// The Barnes–Hut accuracy: 0 is exact (O(n²)), larger is faster and rougher.
        /// Default 0.9.
        public var theta: Double
        /// Distances below this are treated as this, so near-coincident nodes don't fling
        /// each other apart. Default 1.
        public var distanceMin: Double
        /// Nodes farther apart than this ignore each other. Default infinity.
        public var distanceMax: Double

        /// Creates a many-body force; the defaults are d3-force's.
        public init(strength: Double = -30, theta: Double = 0.9, distanceMin: Double = 1, distanceMax: Double = .infinity) {
            self.strength = strength
            self.theta = theta
            self.distanceMin = distanceMin
            self.distanceMax = distanceMax
        }
    }

    /// A pull toward ``x``, ``y`` proportional to the distance from it (d3's `forceX` and
    /// `forceY`): each tick adds `(target - position) × strength × alpha` to the velocity.
    ///
    /// It keeps disconnected components and orphans near the rest of the graph and makes
    /// the graph rounder as it grows stronger. Obsidian's "Center force" maps to it.
    public struct PositionForce: Hashable, Sendable {
        /// The point nodes are pulled toward.
        public var x: Double
        public var y: Double
        /// 0 is off; d3-force's default is 0.1. Default 0.05, enough to hold orphans.
        public var strength: Double

        /// Creates a position force pulling toward (`x`, `y`).
        public init(x: Double = 0, y: Double = 0, strength: Double = 0.05) {
            self.x = x
            self.y = y
            self.strength = strength
        }
    }

    /// Treats nodes as discs that must not overlap (d3's `forceCollide`).
    ///
    /// A node's collision radius is its ``ForceSimulation/radius(at:)`` plus ``padding``.
    /// By default the radius grows with the number of links, like ``ForceGraphView``'s:
    /// `min(radius + radiusPerSqrtDegree × √degree, maximumRadius)`; set a node's radius
    /// directly with ``ForceSimulation/setRadius(_:for:)``.
    public struct CollisionForce: Hashable, Sendable {
        /// How firmly overlaps are resolved per tick, 0…1; 0 turns collision off. Default 1.
        public var strength: Double
        /// The radius of a node without links. Default 4.
        public var radius: Double
        /// How much the radius grows with the square root of the degree. Default 2.
        public var radiusPerSqrtDegree: Double
        /// The largest radius degree can give a node. Default 14.
        public var maximumRadius: Double
        /// Empty space kept around every node, added to its radius. Default 2.
        public var padding: Double
        /// How many times collisions are resolved per tick. Default 1.
        public var iterations: Int

        /// Creates a collision force. The radius defaults match ``ForceGraphView``'s.
        public init(
            strength: Double = 1,
            radius: Double = 4,
            radiusPerSqrtDegree: Double = 2,
            maximumRadius: Double = 14,
            padding: Double = 2,
            iterations: Int = 1
        ) {
            self.strength = strength
            self.radius = radius
            self.radiusPerSqrtDegree = radiusPerSqrtDegree
            self.maximumRadius = maximumRadius
            self.padding = padding
            self.iterations = iterations
        }
    }

    /// Moves every node by the same amount so the mean position lands on ``x``, ``y``
    /// (d3's `forceCenter`). It changes positions, not velocities, so it does not affect
    /// the shape of the graph.
    ///
    /// Off by default: while a node is held, re-centering would slide the rest of the graph
    /// away from the pointer. Use ``PositionForce`` to keep the graph near a point instead.
    public struct CenterForce: Hashable, Sendable {
        /// The point the mean position is moved to.
        public var x: Double
        public var y: Double
        /// 0 is off and 1 centres fully every tick (d3's default when the force is added).
        /// Default 0.
        public var strength: Double

        /// Creates a centering force.
        public init(x: Double = 0, y: Double = 0, strength: Double = 0) {
            self.x = x
            self.y = y
            self.strength = strength
        }
    }
}
