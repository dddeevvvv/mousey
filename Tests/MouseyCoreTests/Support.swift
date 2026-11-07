import CoreGraphics
import Foundation
import MouseyCore

/// The test payload: byte 0 is the kind, bytes 1 and 2 are arguments, bytes 3...6 are an id.
enum Kind: UInt8 {
	case other, keyDown, keyUp, modifierDown, modifierUp, buttonDown, buttonUp, scroll, gesture, keyRepeat
	case unrebuildable = 255
}

func payload(_ kind: Kind, _ a: UInt8 = 0, _ b: UInt8 = 0, id: UInt32 = 0) -> Data {
	Data([kind.rawValue, a, b] + (0..<4).map { UInt8(truncatingIfNeeded: id >> (8 * UInt32($0))) })
}

func payloadID(_ d: Data) -> UInt32 { Array(d)[3...6].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }

func classify(_ d: Data) -> EventClass? {
	let b = Array(d)
	guard b.count >= 7, let kind = Kind(rawValue: b[0]) else { return nil }
	let a = b[1]
	switch kind {
	case .other: return .other
	case .keyDown: return .keyDown(code: UInt16(a), isRepeat: false)
	case .keyRepeat: return .keyDown(code: UInt16(a), isRepeat: true)
	case .keyUp: return .keyUp(code: UInt16(a))
	case .modifierDown: return .modifier(code: UInt16(a), isDown: true)
	case .modifierUp: return .modifier(code: UInt16(a), isDown: false)
	case .buttonDown: return .button(index: Int(a), isDown: true)
	case .buttonUp: return .button(index: Int(a), isDown: false)
	case .scroll: return .scroll(phase: Int(a), momentumPhase: Int(b[2]))
	case .gesture: return .gesture(phase: Int(a), kind: Int(b[2]))
	case .unrebuildable: return nil
	}
}

struct RNG: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed }

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}

	mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
	mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
	mutating func double(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &self) }
}

let ms: Tick = 1_000_000
let second: Tick = 1_000_000_000

let laptop = Displays([CGRect(x: 0, y: 0, width: 1440, height: 900)])
let targetScreen = Displays([CGRect(x: 0, y: 0, width: 2560, height: 1440)])

extension ControllerOutput {
	var frames: [Frame] { effects.compactMap { if case .send(let f) = $0 { return f } else { return nil } } }
	var endCaptures: [CGPoint] { effects.compactMap { if case .endCapture(let p) = $0 { return p } else { return nil } } }
	var beginCaptures: [CGPoint] { effects.compactMap { if case .beginCapture(let p) = $0 { return p } else { return nil } } }
	var roundTrips: [UInt64] { effects.compactMap { if case .roundTrip(let n) = $0 { return n } else { return nil } } }
}

/// Drives a `ControllerCore` by hand with a clock the test controls.
struct Rig {
	var core: ControllerCore
	var now: Tick = 10 * second
	var ackSeq: UInt32 = 0
	/// Acks answer the newest frame sent, as a real target's do.
	var lastFrameSeq: UInt32 = 0
	let edge: Edge
	let session: UInt32 = 7

	init(edge: Edge = .right, local: Displays = laptop) {
		self.edge = edge
		core = ControllerCore(session: 7, edge: edge, displays: local, now: now)
	}

	var isRemote: Bool { core.status.isRemote }

	@discardableResult
	mutating func send(_ input: ControllerInput, after nanos: Tick = 0) -> ControllerOutput {
		now += nanos
		let out = core.handle(input, now: now)
		if let seq = out.frames.last?.seq { lastFrameSeq = seq }
		return out
	}

	@discardableResult
	mutating func ack(
		after nanos: Tick = 0, next: UInt32 = 0, motion: UInt32 = 0, controlled: Bool = false, canInject: Bool = true,
		sent: UInt64? = nil, displays: [CGRect] = targetScreen.frames
	) -> ControllerOutput {
		ackSeq = max(ackSeq + 1, lastFrameSeq)
		return send(
			.ack(Ack(session: session, seq: ackSeq, sentNanos: sent ?? now, nextEventID: next, appliedMotionSeq: motion,
				controlled: controlled, canInject: canInject, displays: displays)), after: nanos)
	}

	/// Pushes through the edge of the laptop at the middle of that edge.
	@discardableResult
	mutating func push(points: Double = 12, steps: Int = 3, every: Tick = 45 * ms, buttonsHeld: Bool = false) -> ControllerOutput {
		var last = send(.tick)
		for _ in 0..<steps {
			last = send(watch(points / Double(steps), buttonsHeld: buttonsHeld), after: every)
			if isRemote { break }
		}
		return last
	}

	/// Repeats a watch event for long enough to pass the push's minimum time, stopping once it crosses.
	@discardableResult
	mutating func sustain(_ input: ControllerInput) -> ControllerOutput {
		var last = send(input, after: 4 * ms)
		for _ in 0..<2 where !isRemote { last = send(input, after: 45 * ms) }
		return last
	}

	func watch(_ outward: Double, buttonsHeld: Bool = false) -> ControllerInput {
		let d = laptop.frames[0]
		switch edge {
		case .right: return .watchMotion(location: CGPoint(x: d.maxX - 0.5, y: 450), dx: outward, dy: 0, buttonsHeld: buttonsHeld)
		case .left: return .watchMotion(location: CGPoint(x: 0.5, y: 450), dx: -outward, dy: 0, buttonsHeld: buttonsHeld)
		case .top: return .watchMotion(location: CGPoint(x: 720, y: 0.5), dx: 0, dy: -outward, buttonsHeld: buttonsHeld)
		case .bottom: return .watchMotion(location: CGPoint(x: 720, y: d.maxY - 0.5), dx: 0, dy: outward, buttonsHeld: buttonsHeld)
		}
	}

	/// Acks a healthy target, then pushes through the edge.
	mutating func cross() {
		ack()
		push()
	}

	@discardableResult
	mutating func motion(_ dx: Double, _ dy: Double, after nanos: Tick = 0, id: UInt32 = 0) -> ControllerOutput {
		send(.grabbedMotion(dx: dx, dy: dy, bytes: payload(.other, id: id)), after: nanos)
	}

	@discardableResult
	mutating func key(_ event: EventClass, id: UInt32 = 0, flags: UInt64 = 0, after nanos: Tick = 0) -> ControllerOutput {
		send(.grabbed(event, bytes: payload(.keyDown, id: id), flags: flags), after: nanos)
	}
}
