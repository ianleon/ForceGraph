// The spatial index behind ForceSimulation's many-body (Barnes–Hut) and collision forces,
// and the kernels of those two forces.
//
// The tree follows d3-quadtree and the forces follow d3-force's forceManyBody and
// forceCollide (both ISC licence, Copyright 2010-2021 Mike Bostock; see NOTICE): a region
// quadtree whose leaves hold one point or a chain of exactly coincident points, split until
// every point has its own leaf. Unlike d3 it is stored flat in raw buffers that keep their
// capacity between builds, so rebuilding it on every tick allocates nothing once it has grown
// to fit the graph, and the traversals run without bounds or exclusivity checks.

/// A flat region quadtree over a set of points, rebuilt in place every tick.
///
/// Scratch space only: nothing in it outlives a force evaluation. `ForceSimulation` holds
/// one and replaces it before use unless it is uniquely referenced, so copies of a
/// simulation never share one; that is what makes the `@unchecked Sendable` sound.
final class QuadTree: @unchecked Sendable {
    /// Marks a leaf that holds no point (the root of a tree before the first insertion).
    static let empty: Int32 = -2
    /// Marks an internal cell, one with children.
    static let internalCell: Int32 = -1
    /// Below this depth a split gives up and chains the points as if they were coincident,
    /// so points a rounding error apart cannot recurse for a thousand levels. It also bounds
    /// the traversal stack.
    static let maximumDepth = 48
    private static let stackCapacity = 4 * (maximumDepth + 2)

    private(set) var cellCount = 0
    private var cellCapacity = 0
    private var pointCapacity = 0

    /// Four child cell indices per cell, `-1` for none, in d3's order: top-left, top-right,
    /// bottom-left, bottom-right (y grows downward, as on screen).
    private var children = UnsafeMutablePointer<Int32>.allocate(capacity: 0)
    /// The first point of a leaf, or `internalCell` or `empty`.
    private var first = UnsafeMutablePointer<Int32>.allocate(capacity: 0)
    /// Each cell's top-left corner and side length.
    private var x0 = UnsafeMutablePointer<Double>.allocate(capacity: 0)
    private var y0 = UnsafeMutablePointer<Double>.allocate(capacity: 0)
    private var size = UnsafeMutablePointer<Double>.allocate(capacity: 0)
    /// Per-cell aggregates the forces fill in after a build: a centre and a value.
    private var cx = UnsafeMutablePointer<Double>.allocate(capacity: 0)
    private var cy = UnsafeMutablePointer<Double>.allocate(capacity: 0)
    private var value = UnsafeMutablePointer<Double>.allocate(capacity: 0)
    /// The next coincident point in a leaf's chain, per point, `-1` at the end.
    private var next = UnsafeMutablePointer<Int32>.allocate(capacity: 0)
    private let stack = UnsafeMutablePointer<Int32>.allocate(capacity: QuadTree.stackCapacity)

    init() {}

    deinit {
        children.deallocate(); first.deallocate()
        x0.deallocate(); y0.deallocate(); size.deallocate()
        cx.deallocate(); cy.deallocate(); value.deallocate()
        next.deallocate(); stack.deallocate()
    }

    // MARK: Storage

    private static func grow<T>(_ pointer: inout UnsafeMutablePointer<T>, from old: Int, to new: Int) {
        let bigger = UnsafeMutablePointer<T>.allocate(capacity: new)
        bigger.moveInitialize(from: pointer, count: old)
        pointer.deallocate()
        pointer = bigger
    }

    private func reserveCells(_ needed: Int) {
        guard needed > cellCapacity else { return }
        let new = max(needed, cellCapacity * 2, 64)
        let old = cellCount
        QuadTree.grow(&children, from: old * 4, to: new * 4)
        QuadTree.grow(&first, from: old, to: new)
        QuadTree.grow(&x0, from: old, to: new)
        QuadTree.grow(&y0, from: old, to: new)
        QuadTree.grow(&size, from: old, to: new)
        // The aggregates are filled after the build, so they need no copying.
        cx.deallocate(); cy.deallocate(); value.deallocate()
        cx = .allocate(capacity: new)
        cy = .allocate(capacity: new)
        value = .allocate(capacity: new)
        cellCapacity = new
    }

    @inline(__always)
    private func appendCell(first point: Int32, x0 cellX: Double, y0 cellY: Double, size cellSize: Double) -> Int32 {
        if cellCount == cellCapacity { reserveCells(cellCount + 1) }
        let c = cellCount
        first[c] = point
        x0[c] = cellX
        y0[c] = cellY
        size[c] = cellSize
        (children + 4 * c).initialize(repeating: -1, count: 4)
        cellCount += 1
        return Int32(c)
    }

    // MARK: Build

    /// Rebuilds the tree over the first `n` points of `x` and `y`, leaving out non-finite ones.
    func build(count n: Int, x: UnsafePointer<Double>, y: UnsafePointer<Double>) {
        cellCount = 0
        if n > pointCapacity {
            next.deallocate()
            next = .allocate(capacity: n)
            pointCapacity = n
        }
        guard n > 0 else { return }

        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for i in 0..<n {
            let a = x[i], b = y[i]
            guard a.isFinite, b.isFinite else { continue }
            if a < minX { minX = a }
            if a > maxX { maxX = a }
            if b < minY { minY = b }
            if b > maxY { maxY = b }
        }
        if minX > maxX { minX = 0; maxX = 0; minY = 0; maxY = 0 }
        var side = max(maxX - minX, maxY - minY)
        if !(side > 0) || !side.isFinite { side = 1 }
        // A hair larger, so the extreme points fall strictly inside the root.
        side *= 1 + 1e-9
        reserveCells(2 * n + 1)
        _ = appendCell(first: QuadTree.empty, x0: minX, y0: minY, size: side)

        for i in 0..<n {
            let xi = x[i], yi = y[i]
            next[i] = -1
            guard xi.isFinite, yi.isFinite else { continue }
            insert(Int32(i), xi, yi, x: x, y: y)
        }
    }

    private func insert(_ i: Int32, _ xi: Double, _ yi: Double, x: UnsafePointer<Double>, y: UnsafePointer<Double>) {
        var c = 0
        var depth = 0
        while true {
            let head = first[c]
            if head == QuadTree.empty {
                first[c] = i
                return
            }
            if head == QuadTree.internalCell {
                let h = size[c] / 2
                let right = xi >= x0[c] + h
                let bottom = yi >= y0[c] + h
                let q = (bottom ? 2 : 0) | (right ? 1 : 0)
                let child = children[4 * c + q]
                if child < 0 {
                    let new = appendCell(first: i, x0: right ? x0[c] + h : x0[c], y0: bottom ? y0[c] + h : y0[c], size: h)
                    children[4 * c + q] = new
                    return
                }
                c = Int(child)
                depth += 1
                continue
            }
            // A leaf holding `head` and its chain.
            let hx = x[Int(head)], hy = y[Int(head)]
            if (hx == xi && hy == yi) || depth >= QuadTree.maximumDepth {
                next[Int(i)] = head
                first[c] = i
                return
            }
            // Split: the cell becomes internal and its chain moves down one level; the loop
            // then descends with `i`, splitting again while the two still share a quadrant.
            let h = size[c] / 2
            let right = hx >= x0[c] + h
            let bottom = hy >= y0[c] + h
            let q = (bottom ? 2 : 0) | (right ? 1 : 0)
            first[c] = QuadTree.internalCell
            let new = appendCell(first: head, x0: right ? x0[c] + h : x0[c], y0: bottom ? y0[c] + h : y0[c], size: h)
            children[4 * c + q] = new
        }
    }

    // MARK: Many-body (Barnes–Hut)

    /// Adds the many-body force to every node's velocity, for a tree built over `x`, `y`.
    ///
    /// Each cell's value is the total strength of its points and its centre their
    /// strength-weighted mean (d3's `accumulate`); a cell narrow enough for its distance
    /// (`width² / theta² < distance²`) acts as one body (d3's `apply`).
    func applyManyBody(
        count n: Int,
        x: UnsafePointer<Double>, y: UnsafePointer<Double>,
        vx: UnsafeMutablePointer<Double>, vy: UnsafeMutablePointer<Double>,
        strength: Double, alpha: Double, theta: Double,
        distanceMin: Double, distanceMax: Double,
        rng: inout SplitMix64
    ) {
        guard cellCount > 0, strength != 0 else { return }
        // Children always come after their parent, so a reverse sweep is a post-order.
        var c = cellCount - 1
        while c >= 0 {
            let head = first[c]
            if head >= 0 {
                var total = 0.0
                var j = head
                while j >= 0 { total += strength; j = next[Int(j)] }
                cx[c] = x[Int(head)]
                cy[c] = y[Int(head)]
                value[c] = total
            } else if head == QuadTree.internalCell {
                var total = 0.0, weight = 0.0, sx = 0.0, sy = 0.0
                for q in 0..<4 {
                    let child = Int(children[4 * c + q])
                    guard child >= 0 else { continue }
                    let v = value[child]
                    guard v != 0 else { continue }
                    let w = abs(v)
                    total += v; weight += w
                    sx += w * cx[child]; sy += w * cy[child]
                }
                if weight > 0 {
                    cx[c] = sx / weight
                    cy[c] = sy / weight
                    value[c] = total
                } else {
                    value[c] = 0
                }
            } else {
                value[c] = 0
            }
            c -= 1
        }

        let theta2 = theta * theta
        let dmin2 = distanceMin * distanceMin
        let dmax2 = distanceMax * distanceMax
        for i in 0..<n {
            let xi = x[i], yi = y[i]
            guard xi.isFinite, yi.isFinite else { continue }
            var ax = 0.0, ay = 0.0
            var top = 0
            stack[0] = 0
            top = 1
            while top > 0 {
                top -= 1
                let c = Int(stack[top])
                let v = value[c]
                if v == 0 { continue }
                var dx = cx[c] - xi
                var dy = cy[c] - yi
                var l = dx * dx + dy * dy
                let w = size[c]
                let head = first[c]
                // Far enough: the whole cell acts as one body.
                if w * w / theta2 < l {
                    if l < dmax2 {
                        if dx == 0 { dx = rng.jiggle(); l += dx * dx }
                        if dy == 0 { dy = rng.jiggle(); l += dy * dy }
                        if l < dmin2 { l = (dmin2 * l).squareRoot() }
                        ax += dx * v * alpha / l
                        ay += dy * v * alpha / l
                    }
                    continue
                }
                if head == QuadTree.internalCell {
                    // Push in reverse so the children are visited in d3's order.
                    var q = 3
                    while q >= 0 {
                        let child = children[4 * c + q]
                        if child >= 0 { stack[top] = child; top += 1 }
                        q -= 1
                    }
                    continue
                }
                if l >= dmax2 { continue }
                // A leaf near enough to treat point by point.
                if Int(head) != i || next[Int(head)] >= 0 {
                    if dx == 0 { dx = rng.jiggle(); l += dx * dx }
                    if dy == 0 { dy = rng.jiggle(); l += dy * dy }
                    if l < dmin2 { l = (dmin2 * l).squareRoot() }
                }
                var j = head
                while j >= 0 {
                    if Int(j) != i {
                        let k = strength * alpha / l
                        ax += dx * k
                        ay += dy * k
                    }
                    j = next[Int(j)]
                }
            }
            vx[i] += ax
            vy[i] += ay
        }
    }

    // MARK: Collision

    /// Pushes overlapping nodes apart, for a tree built over the predicted positions
    /// `px = x + vx`, `py = y + vy` (d3's `forceCollide`). Each overlapping pair is
    /// visited once and separated in proportion to the other's squared radius.
    func applyCollision(
        count n: Int,
        x: UnsafePointer<Double>, y: UnsafePointer<Double>,
        vx: UnsafeMutablePointer<Double>, vy: UnsafeMutablePointer<Double>,
        px: UnsafePointer<Double>, py: UnsafePointer<Double>,
        radii: UnsafePointer<Double>, strength: Double,
        rng: inout SplitMix64
    ) {
        guard cellCount > 0, strength != 0 else { return }
        // Each cell's value is the largest radius inside it (d3's `prepare`).
        var c = cellCount - 1
        while c >= 0 {
            let head = first[c]
            if head >= 0 {
                var r = 0.0
                var j = head
                while j >= 0 { r = max(r, radii[Int(j)]); j = next[Int(j)] }
                value[c] = r
            } else if head == QuadTree.internalCell {
                var r = 0.0
                for q in 0..<4 {
                    let child = Int(children[4 * c + q])
                    if child >= 0 { r = max(r, value[child]) }
                }
                value[c] = r
            } else {
                value[c] = 0
            }
            c -= 1
        }

        for i in 0..<n {
            let ri = radii[i]
            let ri2 = ri * ri
            let xi = x[i] + vx[i], yi = y[i] + vy[i]
            guard xi.isFinite, yi.isFinite else { continue }
            var top = 1
            stack[0] = 0
            while top > 0 {
                top -= 1
                let c = Int(stack[top])
                let head = first[c]
                if head == QuadTree.internalCell {
                    let r = ri + value[c]
                    let cellX0 = x0[c], cellY0 = y0[c], s = size[c]
                    if cellX0 > xi + r || cellX0 + s < xi - r || cellY0 > yi + r || cellY0 + s < yi - r { continue }
                    var q = 3
                    while q >= 0 {
                        let child = children[4 * c + q]
                        if child >= 0 { stack[top] = child; top += 1 }
                        q -= 1
                    }
                    continue
                }
                var j = head
                while j >= 0 {
                    let jj = Int(j)
                    if jj > i {
                        let rj = radii[jj]
                        let r = ri + rj
                        var dx = xi - x[jj] - vx[jj]
                        var dy = yi - y[jj] - vy[jj]
                        var l = dx * dx + dy * dy
                        if l < r * r {
                            if dx == 0 { dx = rng.jiggle(); l += dx * dx }
                            if dy == 0 { dy = rng.jiggle(); l += dy * dy }
                            let d = l.squareRoot()
                            let k = (r - d) / d * strength
                            dx *= k
                            dy *= k
                            let rj2 = rj * rj
                            let share = ri2 + rj2 > 0 ? rj2 / (ri2 + rj2) : 0.5
                            vx[i] += dx * share
                            vy[i] += dy * share
                            vx[jj] -= dx * (1 - share)
                            vy[jj] -= dy * (1 - share)
                        }
                    }
                    j = next[jj]
                }
            }
        }
    }
}

extension SplitMix64 {
    /// A tiny random offset, d3-force's `jiggle`, used to separate coincident nodes.
    @inline(__always)
    mutating func jiggle() -> Double {
        (Double(next() >> 11) * 0x1.0p-53 - 0.5) * 1e-6
    }
}
