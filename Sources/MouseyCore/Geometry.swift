import CoreGraphics

/// Which side of the controller's screen the target sits on.
public enum Edge: UInt8, Sendable, CaseIterable {
	case left, right, top, bottom

	public var opposite: Edge {
		switch self {
		case .left: return .right
		case .right: return .left
		case .top: return .bottom
		case .bottom: return .top
		}
	}

	/// Positions along a left or right edge are y values.
	var runsAlongY: Bool { self == .left || self == .right }

	func outward(dx: Double, dy: Double) -> Double {
		switch self {
		case .right: return dx
		case .left: return -dx
		case .top: return -dy
		case .bottom: return dy
		}
	}
}

extension CGRect {
	func coordinate(of edge: Edge) -> CGFloat {
		switch edge {
		case .left: return minX
		case .right: return maxX
		case .top: return minY
		case .bottom: return maxY
		}
	}

	func distance(to edge: Edge, from p: CGPoint) -> CGFloat {
		switch edge {
		case .left: return p.x - minX
		case .right: return maxX - p.x
		case .top: return p.y - minY
		case .bottom: return maxY - p.y
		}
	}

	func length(along edge: Edge) -> CGFloat { edge.runsAlongY ? height : width }

	/// Rects are half-open, so the far bound is the largest value below it.
	func clamped(_ p: CGPoint) -> CGPoint {
		CGPoint(x: min(max(p.x, minX), maxX.nextDown), y: min(max(p.y, minY), maxY.nextDown))
	}
}

/// Active displays in global coordinates (origin top-left, y grows down). Never empty.
public struct Displays: Equatable, Sendable {
	public private(set) var frames: [CGRect]

	/// Falls back to a single 1x1 frame at the origin if `frames` is empty, so no caller handles an empty list.
	public init(_ frames: [CGRect]) {
		self.frames = frames.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : frames
	}

	/// The display holding `p`, else the nearest one.
	public func display(containing p: CGPoint) -> CGRect {
		if let hit = frames.first(where: { $0.contains(p) }) { return hit }
		func gap(_ r: CGRect) -> CGFloat {
			let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
			return dx * dx + dy * dy
		}
		return frames.min { gap($0) < gap($1) } ?? frames[0]
	}

	/// True when no display lies directly past `edge` of `display` at this point.
	/// A display beside the laptop means the inner edge is not a crossing.
	public func isOuter(_ edge: Edge, of display: CGRect, at p: CGPoint) -> Bool {
		let along = display.clamped(p)
		let probe: CGPoint
		switch edge {
		case .left: probe = CGPoint(x: display.minX - 0.5, y: along.y)
		case .right: probe = CGPoint(x: display.maxX + 0.5, y: along.y)
		case .top: probe = CGPoint(x: along.x, y: display.minY - 0.5)
		case .bottom: probe = CGPoint(x: along.x, y: display.maxY + 0.5)
		}
		return !frames.contains { $0 != display && $0.contains(probe) }
	}

	/// Moves from `p` by the delta. The destination is used when it lies on any display. Otherwise it is clamped to
	/// the current display, and `overshoot` says how far the motion pushed past each edge of that display.
	public func move(from p: CGPoint, dx: Double, dy: Double) -> (point: CGPoint, overshoot: Overshoot) {
		let dest = CGPoint(x: p.x + (dx.isFinite ? dx : 0), y: p.y + (dy.isFinite ? dy : 0))
		if frames.contains(where: { $0.contains(dest) }) { return (dest, Overshoot(left: 0, right: 0, top: 0, bottom: 0)) }
		let d = display(containing: p)
		let over = Overshoot(
			left: Double(max(0, d.minX - dest.x)), right: Double(max(0, dest.x - d.maxX)),
			top: Double(max(0, d.minY - dest.y)), bottom: Double(max(0, dest.y - d.maxY)))
		return (d.clamped(dest), over)
	}

	/// Position along `edge`, in 0...1, for a point on `display`.
	public func fraction(of p: CGPoint, along edge: Edge, on display: CGRect) -> Float {
		let length = display.length(along: edge)
		guard length > 0 else { return 0 }
		let offset = edge.runsAlongY ? p.y - display.minY : p.x - display.minX
		return Float(min(max(offset / length, 0), 1))
	}

	/// The point `inset` points inside `edge` of `display` at this fraction.
	public func point(on edge: Edge, of display: CGRect, fraction: Float, inset: CGFloat) -> CGPoint {
		let f = CGFloat(fraction.isFinite ? min(max(fraction, 0), 1) : 0)
		let x = display.minX + f * display.width, y = display.minY + f * display.height
		let p: CGPoint
		switch edge {
		case .left: p = CGPoint(x: display.minX + inset, y: y)
		case .right: p = CGPoint(x: display.maxX - inset, y: y)
		case .top: p = CGPoint(x: x, y: display.minY + inset)
		case .bottom: p = CGPoint(x: x, y: display.maxY - inset)
		}
		return display.clamped(p)
	}

	/// The display a pointer enters on when arriving through `edge`: the outermost on that side, with ties broken
	/// by the longest length along the edge.
	public func entryDisplay(for edge: Edge) -> CGRect {
		let outward = edge == .left || edge == .top ? frames.map { $0.coordinate(of: edge) }.min() : frames.map { $0.coordinate(of: edge) }.max()
		let outermost = frames.filter { $0.coordinate(of: edge) == outward }
		return outermost.max { $0.length(along: edge) < $1.length(along: edge) } ?? frames[0]
	}
}

public struct Overshoot: Equatable, Sendable {
	public var left, right, top, bottom: Double

	public init(left: Double, right: Double, top: Double, bottom: Double) {
		self.left = left
		self.right = right
		self.top = top
		self.bottom = bottom
	}

	public subscript(edge: Edge) -> Double {
		switch edge {
		case .left: return left
		case .right: return right
		case .top: return top
		case .bottom: return bottom
		}
	}
}

/// Resistance at a screen edge. Feeds on outward motion. Starts over after a pause or when reset.
public struct EdgePush: Equatable, Sendable {
	private var pushed = 0.0
	private var started: Tick?
	private var last: Tick?

	public init() {}

	/// Returns true once, on the event that has both pushed `Tuning.edgePushPoints` and kept pushing for
	/// `Tuning.edgePushMinNanos`, then starts over.
	public mutating func feed(outward: Double, now: Tick) -> Bool {
		guard outward > 0 else { return false }
		if let last, elapsed(now, since: last) > Tuning.edgePushPauseNanos { self = EdgePush() }
		let start = started ?? now
		started = start
		last = now
		pushed += outward
		guard pushed >= Tuning.edgePushPoints, elapsed(now, since: start) >= Tuning.edgePushMinNanos else { return false }
		self = EdgePush()
		return true
	}

	public mutating func reset() { self = EdgePush() }
}
