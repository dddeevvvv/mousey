import CoreGraphics
import Foundation
import MouseyCore
import XCTest

struct Conditions {
	var loss = 0.0
	var duplication = 0.0
	var delay: ClosedRange<Tick> = 2 * ms...10 * ms
	var reorder = 0.0
	var reorderSpread: Tick = 0
	var partition: Range<Tick>?
	/// Packets sent during a partition arrive after it ends instead of being lost.
	var holdDuringPartition = false
}

/// A seeded in-memory link between a `ControllerCore` and a `TargetCore`, with simulated time. It plays the shell on
/// both sides: it calls `.tick` when `nextTick` says, feeds the crossing event back, and applies the target's commands to
/// a model of what is held. Expected values come from the script it generates, never from the cores.
final class LinkSim {
	struct Capture { var index: Int; var position: CGPoint }
	struct Post { var index: Int; var isMotion: Bool; var at: CGPoint; var maxSeqDelivered: UInt32 }
	struct Return { var returnSeq: UInt32 = 0; var abandoned: Set<Int> }
	struct Session { var forwarded: [Capture] = []; var cut = false; var drained = false; var finalPosition = CGPoint.zero; var lastPostAtDrain = CGPoint.zero }
	private struct Packet { var at: Tick; var toTarget: Bool; var data: Data }

	let seed: UInt64
	var rng: RNG
	var now: Tick = 10 * second
	var cond: Conditions
	let edge: Edge
	let local: Displays
	let target: CGRect
	private var ctl: ControllerCore
	private var tgt: TargetCore
	private var inflight: [Packet] = []
	private var ctlNext: Tick
	private var tgtNext: Tick
	private var entry = CGPoint.zero
	private var index = 0
	private var pos = CGPoint.zero
	private var maxSeqDelivered: UInt32 = 0

	private(set) var sessions: [Session] = []
	private(set) var posts: [Post] = []
	private(set) var returns: [Return] = []
	private(set) var postedEvents = Set<Int>()
	private(set) var endCaptureTimes: [Tick] = []
	private(set) var beginCaptureCount = 0
	private(set) var lastAckDelivered: Tick = 0
	private(set) var lastFrameDelivered: Tick = 0
	private(set) var targetCommandCount = 0

	private var keys = Set<UInt16>(), modifiers = Set<UInt16>(), buttons = Set<Int>()
	private var scrollOpen = false, gestureOpen = false
	private(set) var emptiedAt: Tick?
	var heldEmpty: Bool { keys.isEmpty && modifiers.isEmpty && buttons.isEmpty && !scrollOpen && !gestureOpen }

	private var heldKeys: [UInt8] = []
	private var heldModifiers: [UInt8] = []
	private var heldButton: UInt8?
	private var scroll = ScrollState.idle
	private var gesture = false
	private enum ScrollState { case idle, finger, momentum }

	init(seed: UInt64, cond: Conditions? = nil) {
		self.seed = seed
		var rng = RNG(seed: seed)
		edge = Edge.allCases[rng.int(0...3)]
		let w = rng.double(1200...1800), h = rng.double(700...1100)
		local = rng.chance(0.3)
			? Displays([CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: w, y: rng.double(-200...200), width: rng.double(1000...2000), height: rng.double(700...1400))])
			: Displays([CGRect(x: 0, y: 0, width: w, height: h)])
		target = CGRect(x: rng.double(-3000...500), y: rng.double(-500...300), width: rng.double(800...3000), height: rng.double(600...1800))
		self.cond = cond ?? LinkSim.randomConditions(&rng)
		ctl = ControllerCore(session: UInt32(seed &+ 1), edge: edge, displays: local, now: 10 * second)
		tgt = TargetCore(displays: Displays([target]), classify: classify)
		ctlNext = 10 * second
		tgtNext = 10 * second
		self.rng = rng
	}

	static func randomConditions(_ rng: inout RNG) -> Conditions {
		var c = Conditions()
		c.loss = rng.chance(0.7) ? rng.double(0...0.3) : 0
		c.duplication = rng.chance(0.5) ? rng.double(0...0.1) : 0
		let lo = Tick(rng.int(2...20)) * ms
		c.delay = lo...(lo + Tick(rng.int(0...20)) * ms)
		c.reorder = rng.chance(0.6) ? rng.double(0.1...0.6) : 0
		c.reorderSpread = Tick(rng.int(5...60)) * ms
		return c
	}

	// MARK: Event loop

	var isRemote: Bool { ctl.status.isRemote }
	var lastReturn: ReturnReason? { ctl.status.lastReturn }

	func run(until t: Tick) {
		for _ in 0..<1_000_000 {
			let packet = inflight.indices.min { inflight[$0].at < inflight[$1].at }
			var next = min(ctlNext, tgtNext)
			if let packet { next = min(next, inflight[packet].at) }
			guard next <= t else { break }
			now = max(now, next)
			if let packet, inflight[packet].at <= now {
				deliver(inflight.remove(at: packet))
			} else if ctlNext <= now {
				drive(.tick)
			} else {
				for c in coalesce(tgt.tick(now: now)) { apply(c) }
				tgtNext = now + 200 * ms
			}
		}
		now = max(now, t)
	}

	func run(for d: Tick) { run(until: now + d) }

	private func send(_ data: Data, toTarget: Bool) {
		let partitioned = cond.partition?.contains(now) ?? false
		if partitioned && !cond.holdDuringPartition { return }
		if rng.chance(cond.loss) { return }
		for _ in 0..<(rng.chance(cond.duplication) ? 2 : 1) {
			var delay = Tick(rng.int(Int(cond.delay.lowerBound)...Int(cond.delay.upperBound)))
			if rng.chance(cond.reorder) { delay += Tick(rng.int(0...Int(cond.reorderSpread))) }
			let base = partitioned ? cond.partition!.upperBound : now
			inflight.append(Packet(at: base + delay, toTarget: toTarget, data: data))
		}
	}

	private func deliver(_ p: Packet) {
		if p.toTarget {
			guard let frame = Wire.decodeFrame(p.data) else { return XCTFail("seed \(seed): frame did not decode") }
			maxSeqDelivered = max(maxSeqDelivered, frame.seq)
			lastFrameDelivered = now
			let r = tgt.receive(frame, canInject: true, now: now)
			for c in coalesce(r.commands) { apply(c) }
			send(Wire.encode(r.ack), toTarget: false)
		} else {
			guard let ack = Wire.decodeAck(p.data) else { return XCTFail("seed \(seed): ack did not decode") }
			lastAckDelivered = now
			drive(.ack(ack))
		}
	}

	@discardableResult
	func drive(_ input: ControllerInput) -> ControllerOutput {
		let out = ctl.handle(input, now: now)
		ctlNext = out.nextTick
		var capture = false
		for effect in out.effects {
			switch effect {
			case .send(let frame):
				if !frame.isRemote, let last = returns.indices.last, returns[last].returnSeq == 0, endCaptureTimes.count == returns.count { returns[last].returnSeq = frame.seq }
				send(Wire.encode(frame), toTarget: true)
			case .beginCapture:
				beginCaptureCount += 1
				pos = entry
				sessions.append(Session())
				capture = true
			case .endCapture:
				endCaptureTimes.append(now)
				returns.append(Return(abandoned: Set(sessions[sessions.count - 1].forwarded.map(\.index).filter { !postedEvents.contains($0) })))
			case .roundTrip:
				break
			}
		}
		if capture { captureMotion(dx: 0, dy: 0) }
		return out
	}

	// MARK: Target side model

	private func apply(_ command: TargetCommand) {
		targetCommandCount += 1
		let seen = maxSeqDelivered
		switch command {
		case .postMotion(let bytes, let at):
			posts.append(Post(index: Int(payloadID(bytes)), isMotion: true, at: at, maxSeqDelivered: seen))
		case .post(let bytes, let at):
			let event = classify(bytes)!
			switch event {
			case .keyDown(let code, true):
				XCTAssertTrue(keys.contains(code), "seed \(seed): repeat of a key that is not held")
				return
			case .keyDown(let code, false): keys.insert(code)
			case .keyUp(let code): keys.remove(code)
			case .modifier(let code, let down): if down { modifiers.insert(code) } else { modifiers.remove(code) }
			case .button(let i, let down): if down { buttons.insert(i) } else { buttons.remove(i) }
			case .scroll(let phase, let momentum): scrollOpen = [1, 2, 128].contains(phase) || [1, 2].contains(momentum)
			case .gesture(let phase, _): gestureOpen = [1, 2, 128].contains(phase)
			case .other: break
			}
			postedEvents.insert(Int(payloadID(bytes)))
			posts.append(Post(index: Int(payloadID(bytes)), isMotion: false, at: at, maxSeqDelivered: seen))
		case .releaseKey(let code): XCTAssertNotNil(keys.remove(code), "seed \(seed): released key \(code) that was not held")
		case .releaseModifier(let code): XCTAssertNotNil(modifiers.remove(code), "seed \(seed): released modifier \(code) that was not held")
		case .releaseButton(let i, _): XCTAssertNotNil(buttons.remove(i), "seed \(seed): released button \(i) that was not held")
		case .endScroll: XCTAssertTrue(scrollOpen, "seed \(seed): ended a scroll that was not open"); scrollOpen = false
		case .endGesture: XCTAssertTrue(gestureOpen, "seed \(seed): ended a gesture that was not open"); gestureOpen = false
		case .declareUserActivity: break
		}
		if heldEmpty, case .declareUserActivity = command {} else if heldEmpty { emptiedAt = now }
	}

	// MARK: Controller side script

	/// Pushes through the edge until the controller crosses, or gives up after 90 simulated seconds.
	func cross() -> Bool {
		let dep = local.entryDisplay(for: edge)
		let f = rng.double(0.05...0.95)
		let loc: CGPoint, outward = rng.double(2...8)
		let delta: (Double, Double)
		switch edge {
		case .right: loc = CGPoint(x: dep.maxX - 0.5, y: dep.minY + f * dep.height); delta = (outward, 0)
		case .left: loc = CGPoint(x: dep.minX + 0.5, y: dep.minY + f * dep.height); delta = (-outward, 0)
		case .top: loc = CGPoint(x: dep.minX + f * dep.width, y: dep.minY + 0.5); delta = (0, -outward)
		case .bottom: loc = CGPoint(x: dep.minX + f * dep.width, y: dep.maxY - 0.5); delta = (0, outward)
		}
		let fraction = local.fraction(of: loc, along: edge, on: dep)
		entry = Displays([target]).point(on: edge.opposite, of: target, fraction: fraction, inset: 1)
		let deadline = now + 90 * second
		while !isRemote && now < deadline {
			run(for: 4 * ms)
			drive(.watchMotion(location: loc, dx: delta.0, dy: delta.1, buttonsHeld: false))
		}
		heldKeys = []; heldModifiers = []; heldButton = nil; scroll = .idle; gesture = false
		return isRemote
	}

	/// Real `CGEvent.data` is 170 to 250 bytes, so a few pending events already fill a datagram.
	private func padded(_ d: Data) -> Data { d + Data(repeating: 0, count: rng.int(0...250)) }

	@discardableResult
	func captureMotion(dx: Double, dy: Double) -> Bool {
		index += 1
		var dx = dx, dy = dy
		// Stay clear of the exit edge, so the script is not cut short by its own motion.
		switch edge.opposite {
		case .left where pos.x + dx < target.minX: dx = abs(dx)
		case .right where pos.x + dx > target.maxX: dx = -abs(dx)
		case .top where pos.y + dy < target.minY: dy = abs(dy)
		case .bottom where pos.y + dy > target.maxY: dy = -abs(dy)
		default: break
		}
		let out = drive(.grabbedMotion(dx: dx, dy: dy, bytes: padded(payload(.other, id: UInt32(index)))))
		guard out.disposition == .consume, isRemote else { return false }
		pos = CGPoint(x: min(max(pos.x + dx, target.minX), target.maxX.nextDown), y: min(max(pos.y + dy, target.minY), target.maxY.nextDown))
		return true
	}

	func captureEvent(_ kind: Kind, _ a: UInt8 = 0, _ b: UInt8 = 0) {
		index += 1
		let bytes = padded(payload(kind, a, b, id: UInt32(index)))
		let out = drive(.grabbed(classify(bytes)!, bytes: bytes, flags: 0))
		if kind != .keyRepeat, out.disposition == .consume, isRemote {
			sessions[sessions.count - 1].forwarded.append(Capture(index: index, position: pos))
		}
	}

	/// One random user action, always legal for what is held.
	func step() {
		switch rng.int(0...99) {
		case 0..<45:
			captureMotion(dx: rng.double(-30...30), dy: rng.double(-30...30))
		case 45..<52:
			if let b = heldButton { captureEvent(.buttonUp, b); heldButton = nil } else { heldButton = UInt8(rng.int(0...2)); captureEvent(.buttonDown, heldButton!) }
		case 52..<62:
			if heldKeys.count < 3, heldKeys.isEmpty || rng.chance(0.4) {
				let code = UInt8(rng.int(0...40))
				guard !heldKeys.contains(code) else { return }
				heldKeys.append(code)
				captureEvent(.keyDown, code)
			} else if let code = heldKeys.randomElement(using: &rng) {
				if rng.chance(0.6) { captureEvent(.keyRepeat, code) } else { heldKeys.removeAll { $0 == code }; captureEvent(.keyUp, code) }
			}
		case 62..<68:
			if let code = heldModifiers.last, rng.chance(0.5) { heldModifiers.removeLast(); captureEvent(.modifierUp, code) } else if heldModifiers.count < 3 {
				let code = UInt8(54 + heldModifiers.count)
				heldModifiers.append(code)
				captureEvent(.modifierDown, code)
			}
		case 68..<80:
			switch scroll {
			case .idle: scroll = .finger; captureEvent(.scroll, 1, 0)
			case .finger:
				if rng.chance(0.7) { captureEvent(.scroll, 2, 0) } else if rng.chance(0.5) { scroll = .idle; captureEvent(.scroll, 4, 0) } else { scroll = .idle; captureEvent(.scroll, 4, 0); scroll = .momentum; captureEvent(.scroll, 0, 1) }
			case .momentum:
				if rng.chance(0.6) { captureEvent(.scroll, 0, 2) } else { scroll = .idle; captureEvent(.scroll, 0, 3) }
			}
		case 80..<84:
			gesture.toggle()
			captureEvent(.gesture, gesture ? 1 : 4)
		default:
			captureEvent(.other)
		}
	}

	/// One session: cross, act, then either wait until the target caught up or leave at once.
	func runSession(steps: Int, drain: Bool) {
		guard cross() else { return }
		let s = sessions.count - 1
		let postsBefore = posts.count
		if rng.chance(0.35) {
			let start = now + Tick(rng.int(50...1500)) * ms
			cond.partition = start..<(start + Tick(rng.int(100...1800)) * ms)
			cond.holdDuringPartition = rng.chance(0.5)
		}
		for _ in 0..<steps {
			guard isRemote else { break }
			switch rng.int(0...19) {
			case 0: run(for: Tick(rng.int(100...400)) * ms)
			case 1..<4: run(for: Tick(rng.int(8...30)) * ms)
			case 4..<6: break
			default: run(for: Tick(rng.int(1...8)) * ms)
			}
			guard isRemote else { break }
			step()
		}
		guard isRemote else { sessions[s].cut = true; return }
		if drain {
			let deadline = now + 30 * second
			while isRemote && now < deadline && !isCaughtUp(session: s, since: postsBefore) { run(for: 5 * ms) }
			if isRemote {
				sessions[s].drained = isCaughtUp(session: s, since: postsBefore)
				sessions[s].finalPosition = pos
				sessions[s].lastPostAtDrain = posts.last?.at ?? .zero
			}
		}
		sessions[s].cut = !sessions[s].drained
		if rng.chance(0.3) {
			drive(.grabbed(.keyDown(code: 53, isRepeat: false), bytes: payload(.keyDown, 53), flags: 0x1C0000))
		} else {
			drive(.fault(.disabled))
		}
	}

	private func isCaughtUp(session s: Int, since postsBefore: Int) -> Bool {
		guard posts.count > postsBefore, let last = posts.last else { return false }
		return sessions[s].forwarded.allSatisfy { postedEvents.contains($0.index) }
			&& abs(last.at.x - pos.x) < 1e-6 && abs(last.at.y - pos.y) < 1e-6
	}

	// MARK: Checks

	func verify() {
		let who = "seed \(seed)"
		let order = posts.map(\.index)
		for (a, b) in zip(order, order.dropFirst()) where a >= b {
			XCTFail("\(who): post of capture \(b) came after capture \(a) was posted (events exactly once, motion and events in capture order)")
			break
		}
		for (n, s) in sessions.enumerated() {
			let posted = s.forwarded.map { postedEvents.contains($0.index) }
			if let firstMissing = posted.firstIndex(of: false), posted[firstMissing...].contains(true) {
				XCTFail("\(who): session \(n) delivered event \(s.forwarded[posted.lastIndex(of: true)!].index) but skipped \(s.forwarded[firstMissing].index)")
			}
			if s.drained, posted.contains(false) { XCTFail("\(who): session \(n) was drained but \(s.forwarded.filter { !postedEvents.contains($0.index) }.map(\.index)) never arrived") }
			if s.drained {
				XCTAssertEqual(s.lastPostAtDrain.x, s.finalPosition.x, accuracy: 1e-6, "\(who): final x of session \(n)")
				XCTAssertEqual(s.lastPostAtDrain.y, s.finalPosition.y, accuracy: 1e-6, "\(who): final y of session \(n)")
			}
		}
		let capturedAt = Dictionary(sessions.flatMap(\.forwarded).map { ($0.index, $0.position) }, uniquingKeysWith: { a, _ in a })
		for p in posts where !p.isMotion {
			guard let want = capturedAt[p.index] else { XCTFail("\(who): posted event \(p.index) was never forwarded"); continue }
			if abs(p.at.x - want.x) > 1e-6 || abs(p.at.y - want.y) > 1e-6 { XCTFail("\(who): event \(p.index) posted at \(p.at), captured at \(want)") }
		}
		for r in returns {
			for p in posts where !p.isMotion && r.abandoned.contains(p.index) && p.maxSeqDelivered >= r.returnSeq {
				XCTFail("\(who): abandoned event \(p.index) was posted after the target saw return frame \(r.returnSeq)")
			}
		}
		XCTAssertTrue(heldEmpty, "\(who): input still held on the target: keys \(keys) modifiers \(modifiers) buttons \(buttons) scroll \(scrollOpen) gesture \(gestureOpen)")
	}

	/// Heal the link and let both sides settle, so a held key has had every chance to be released.
	func settle() {
		cond.loss = 0
		cond.duplication = 0
		cond.partition = nil
		run(for: 4 * second)
	}

	var abandonedCount: Int { returns.reduce(0) { $0 + $1.abandoned.count } }
}
