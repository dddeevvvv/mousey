import Foundation
import CoreGraphics

/// Which Mac saw this key go down. See DESIGN.md, "Held keys".
public struct KeyRouter: Equatable, Sendable {
	public enum Route: Equatable, Sendable { case forward, forwardAsRepeat, passToLocal }

	private var held = Set<UInt16>()

	public init() {}

	public mutating func route(_ event: EventClass) -> Route {
		switch event {
		case .keyDown(let code, let isRepeat):
			if isRepeat { return held.contains(code) ? .forwardAsRepeat : .passToLocal }
			held.insert(code)
			return .forward
		case .modifier(let code, true):
			held.insert(code)
			return .forward
		case .keyUp(let code), .modifier(let code, false):
			return held.remove(code) != nil ? .forward : .passToLocal
		default:
			return .forward
		}
	}

	public mutating func reset() { held.removeAll() }
}

public enum ReturnReason: Equatable, Sendable {
	case targetEdge
	case targetSilent, targetCannotInject, outboxFull, socketError, tapDisabled, panicChord, secureInput
	case sleep, screenLocked, sessionChanged, clockGap, terminating, disabled
}

public enum ControllerInput: Sendable {
	/// From the listen-only watch tap. Ignored while remote.
	case watchMotion(location: CGPoint, dx: Double, dy: Double, buttonsHeld: Bool)
	/// From the grab tap, for moved and dragged events. Ignored while local.
	case grabbedMotion(dx: Double, dy: Double, bytes: Data)
	/// From the grab tap, for everything else. `flags` lets the core recognise the panic chord.
	case grabbed(EventClass, bytes: Data, flags: UInt64)
	case ack(Ack)
	case tick
	case localDisplays(Displays)
	case fault(ReturnReason)
	/// No crossing while locked, so nobody at a locked keyboard Mac can drive the other Mac. Locking also returns.
	case locked(Bool)
	/// While on, a frame goes out every `Tuning.probeNanos`, for the latency test.
	case probing(Bool)
}

public enum ControllerEffect: Equatable, Sendable {
	case send(Frame)
	/// Enable the grab tap, hide, warp to `parkAt`, disassociate. Then the shell feeds the crossing event back as
	/// `.grabbedMotion(dx: 0, dy: 0, bytes:)`, so the target places its pointer even if the user stops pushing.
	case beginCapture(parkAt: CGPoint)
	/// Disable the grab tap, warp to `warpTo`, re-associate, show. Idempotent in the shell.
	case endCapture(warpTo: CGPoint)
	/// One round-trip sample. The shell aggregates these for the menu and the latency test.
	case roundTrip(nanos: UInt64)
}

public enum Disposition: Equatable, Sendable { case consume, pass }

public struct ControllerOutput: Equatable, Sendable {
	public var effects: [ControllerEffect]
	/// What the grab tap returns for this event. Meaningful only for `.grabbed` and `.grabbedMotion`.
	public var disposition: Disposition
	/// When the shell must call `.tick` next. 5 ms with unconfirmed work on an answering link, 100 ms while remote,
	/// 1 s while local.
	public var nextTick: Tick
}

public struct ControllerStatus: Equatable, Sendable {
	public var isRemote: Bool
	public var targetOnline: Bool
	public var targetCanInject: Bool
	public var lastReturn: ReturnReason?
}

/// Invariants:
/// `.remote` is left only through one private `returnToLocal`, which is idempotent.
/// It never enters unless the target acked within `onlineWindowNanos` with `canInject`, and no button is held.
/// Silence is measured from the later of the last ack and the moment of crossing, so entering cannot trip it.
/// No ack for `targetSilentReturnNanos` while remote returns to local. So does a gap over `clockGapNanos` between
/// any two `handle` calls while remote, and an ack that says the target can no longer inject.
/// These liveness checks run at the start of EVERY `handle` call while remote, not only on `.tick`. A shell that
/// re-arms its timer on each output would otherwise never fire `.tick` during continuous motion.
/// Crossing again needs an ack of the return frame or later, so the target has seen the return.
/// `nextTick` is the earliest of the next heartbeat or retry and the silence deadline, so a quiet line still gets
/// its silence check on time.
/// The target edge exit needs no button held on the target, and an outer edge.
/// Every frame is complete, so calling `.tick` extra times is harmless.
public struct ControllerCore: Sendable {
	private struct Remote: Sendable {
		let departure: CGRect
		let departureFraction: Float
		let crossedAt: Tick
		var router = KeyRouter()
		var buttons = Set<Int>()
		var exitPush = EdgePush()
	}

	private static let panicCode: UInt16 = 53
	private static let panicFlags: UInt64 = 0x40000 | 0x80000 | 0x100000

	private let session: UInt32
	private let edge: Edge
	private var local: Displays
	private var target: Displays?
	/// On the target. Stale while local.
	private var position = CGPoint.zero
	private var remote: Remote?
	private var push = EdgePush()
	private var outbox = Outbox()
	private var repeats: [Data] = []
	private var motionSeq: UInt32 = 0
	private var latestMotion: Data?
	private var confirmedMotion: UInt32 = 0
	private var seq: UInt32 = 0
	private var lastSend: Tick?
	private var lastHandle: Tick
	private var lastAck: Tick?
	private var newestAck: UInt32?
	private var canInject = false
	private var controlled = false
	private var lastReturn: ReturnReason?
	private var returnSeq: UInt32?
	private var locked = false
	private var smoothedRoundTrip: Tick?
	private var probing = false

	public init(session: UInt32, edge: Edge, displays: Displays, now: Tick) {
		self.session = session
		self.edge = edge
		local = displays
		lastHandle = now
	}

	public var status: ControllerStatus {
		ControllerStatus(isRemote: remote != nil, targetOnline: isOnline(lastHandle), targetCanInject: canInject, lastReturn: lastReturn)
	}

	public mutating func handle(_ input: ControllerInput, now: Tick) -> ControllerOutput {
		var effects: [ControllerEffect] = []
		var disposition = Disposition.pass
		if let reason = livenessFailure(now: now) { returnToLocal(reason, now: now, effects: &effects) }
		lastHandle = now
		switch input {
		case .watchMotion(let location, let dx, let dy, let buttonsHeld):
			if remote == nil { watch(location, dx: dx, dy: dy, buttonsHeld: buttonsHeld, now: now, effects: &effects) }
		case .grabbedMotion(let dx, let dy, let bytes):
			if remote != nil {
				disposition = .consume
				grabbedMotion(dx: dx, dy: dy, bytes: bytes, now: now, effects: &effects)
			}
		case .grabbed(let event, let bytes, let flags):
			if remote != nil { disposition = grabbed(event, bytes: bytes, flags: flags, now: now, effects: &effects) }
		case .ack(let ack):
			apply(ack, now: now, effects: &effects)
		case .tick:
			if frameDue(now: now) <= now { effects.append(.send(makeFrame(now: now))) }
		case .localDisplays(let displays):
			local = displays
		case .fault(let reason):
			returnToLocal(reason, now: now, effects: &effects)
		case .locked(let on):
			locked = on
			if on { returnToLocal(.screenLocked, now: now, effects: &effects) }
		case .probing(let on):
			probing = on
		}
		return ControllerOutput(effects: effects, disposition: disposition, nextTick: nextTick(now: now))
	}

	private func silenceBase(_ remote: Remote) -> Tick { max(lastAck ?? 0, remote.crossedAt) }

	private func livenessFailure(now: Tick) -> ReturnReason? {
		guard let remote else { return nil }
		if elapsed(now, since: lastHandle) > Tuning.clockGapNanos { return .clockGap }
		if elapsed(now, since: silenceBase(remote)) > Tuning.targetSilentReturnNanos { return .targetSilent }
		if !canInject { return .targetCannotInject }
		return nil
	}

	private func isOnline(_ now: Tick) -> Bool {
		lastAck.map { elapsed(now, since: $0) <= Tuning.onlineWindowNanos } ?? false
	}

	/// An ack of an older frame is not enough: the target may not have seen the return, and a key held across it would stick.
	private var answeredSinceReturn: Bool {
		guard let returnSeq else { return true }
		return newestAck.map { !isNewer(returnSeq, than: $0) } ?? false
	}

	private mutating func watch(_ location: CGPoint, dx: Double, dy: Double, buttonsHeld: Bool, now: Tick, effects: inout [ControllerEffect]) {
		let display = local.display(containing: location)
		guard display.distance(to: edge, from: location) <= 1 else { return push.reset() }
		let outward = edge.outward(dx: dx, dy: dy)
		guard local.isOuter(edge, of: display, at: location), outward > 0 else { return }
		guard !locked, !buttonsHeld, canInject, isOnline(now), answeredSinceReturn, target != nil else { return push.reset() }
		guard push.feed(outward: outward, now: now) else { return }
		cross(from: display, at: location, now: now, effects: &effects)
	}

	private mutating func cross(from display: CGRect, at location: CGPoint, now: Tick, effects: inout [ControllerEffect]) {
		guard let target else { return }
		let fraction = local.fraction(of: location, along: edge, on: display)
		position = target.point(on: edge.opposite, of: target.entryDisplay(for: edge.opposite), fraction: fraction, inset: 1)
		remote = Remote(departure: display, departureFraction: fraction, crossedAt: now)
		push.reset()
		effects.append(.beginCapture(parkAt: CGPoint(x: display.midX, y: display.midY)))
		effects.append(.send(makeFrame(now: now)))
	}

	private mutating func grabbedMotion(dx: Double, dy: Double, bytes: Data, now: Tick, effects: inout [ControllerEffect]) {
		guard var r = remote, let target else { return }
		let moved = target.move(from: position, dx: dx, dy: dy)
		position = moved.point
		let exit = edge.opposite
		let display = target.display(containing: position)
		let overshoot = moved.overshoot[exit]
		if display.distance(to: exit, from: position) > 1 {
			r.exitPush.reset()
		} else if overshoot > 0, target.isOuter(exit, of: display, at: position), r.buttons.isEmpty,
			r.exitPush.feed(outward: overshoot, now: now) {
			let fraction = target.fraction(of: position, along: exit, on: display)
			return returnToLocal(.targetEdge, exitFraction: fraction, now: now, effects: &effects)
		}
		remote = r
		motionSeq &+= 1
		latestMotion = bytes
		effects.append(.send(makeFrame(now: now)))
	}

	private mutating func grabbed(_ event: EventClass, bytes: Data, flags: UInt64, now: Tick, effects: inout [ControllerEffect]) -> Disposition {
		if case .keyDown(Self.panicCode, _) = event, flags & Self.panicFlags == Self.panicFlags {
			returnToLocal(.panicChord, now: now, effects: &effects)
			return .consume
		}
		guard var r = remote else { return .pass }
		let route = r.router.route(event)
		if route == .forward, case .button(let index, let isDown) = event {
			if isDown { r.buttons.insert(index) } else { r.buttons.remove(index) }
		}
		remote = r
		switch route {
		case .passToLocal:
			return .pass
		case .forwardAsRepeat:
			repeats.append(bytes)
		case .forward:
			guard outbox.append(WireEvent(x: position.x, y: position.y, motionSeq: motionSeq, bytes: bytes)) else {
				returnToLocal(.outboxFull, now: now, effects: &effects)
				return .consume
			}
		}
		effects.append(.send(makeFrame(now: now)))
		return .consume
	}

	private mutating func apply(_ ack: Ack, now: Tick, effects: inout [ControllerEffect]) {
		guard ack.session == session else { return }
		if let newest = newestAck, !isNewer(ack.seq, than: newest) { return }
		newestAck = ack.seq
		lastAck = now
		if !ack.displays.isEmpty { target = Displays(ack.displays) }
		canInject = ack.canInject
		controlled = ack.controlled
		outbox.acknowledge(next: ack.nextEventID)
		if isNewer(ack.appliedMotionSeq, than: confirmedMotion) { confirmedMotion = ack.appliedMotionSeq }
		if ack.sentNanos <= now {
			let sample = now - ack.sentNanos
			smoothedRoundTrip = smoothedRoundTrip.map { ($0 * 7 + sample) / 8 } ?? sample
			effects.append(.roundTrip(nanos: sample))
		}
	}

	/// The only way out of remote. Events not yet confirmed are abandoned, so nothing typed during a stall appears late.
	private mutating func returnToLocal(_ reason: ReturnReason, exitFraction: Float? = nil, now: Tick, effects: inout [ControllerEffect]) {
		guard let r = remote else { return }
		remote = nil
		let departure = local.frames.contains(r.departure)
			? r.departure : local.display(containing: CGPoint(x: r.departure.midX, y: r.departure.midY))
		let warp = local.point(on: edge, of: departure, fraction: exitFraction ?? r.departureFraction, inset: 2)
		outbox.clear()
		repeats = []
		latestMotion = nil
		confirmedMotion = motionSeq
		push.reset()
		lastReturn = reason
		effects.append(.endCapture(warpTo: warp))
		effects.append(.send(makeFrame(now: now)))
		returnSeq = seq
	}

	private var motionUnconfirmed: Bool { latestMotion != nil && isNewer(motionSeq, than: confirmedMotion) }

	/// Every frame comes from here. Motion rides along only when every pending event fits with it. Otherwise a motion
	/// newer than a withheld event would be posted before that event. What fits is decided after compression.
	private mutating func makeFrame(now: Tick) -> Frame {
		seq &+= 1
		lastSend = now
		var room = Wire.maxDatagram - Wire.frameHeaderSize
		var sentRepeats: [Data] = []
		for r in repeats {
			guard r.count + 2 <= room else { break }
			room -= r.count + 2
			sentRepeats.append(r)
		}
		repeats = []
		// Compression has not beaten 4:1 on real events, so this bounds the work during a backlog without limiting the fit.
		let pending = outbox.pending(budget: Wire.maxDatagram * 5)
		var frame = Frame(
			session: session, seq: seq, sentNanos: now, isRemote: remote != nil, x: position.x, y: position.y, motionSeq: motionSeq,
			motion: motionUnconfirmed && pending.events.count == outbox.count ? latestMotion : nil,
			firstEventID: pending.firstID, events: pending.events, repeats: sentRepeats)
		var size = Wire.encode(frame).count
		if size > Wire.maxDatagram, frame.motion != nil {
			frame.motion = nil
			size = Wire.encode(frame).count
		}
		while size > Wire.maxDatagram, frame.events.count > 1 {
			// Size is close to linear in the event count, so this lands near the fit in a pass or two.
			let keep = max(1, min(frame.events.count - 1, frame.events.count * Wire.maxDatagram / size))
			frame.events.removeLast(frame.events.count - keep)
			size = Wire.encode(frame).count
		}
		return frame
	}

	private func frameDue(now: Tick) -> Tick {
		guard let sent = lastSend else { return now }
		if probing { return sent &+ Tuning.probeNanos }
		let unconfirmed = !outbox.isEmpty || motionUnconfirmed || controlled != (remote != nil)
		let answering = lastAck.map { elapsed(now, since: $0) <= Tuning.fastRetryWindowNanos } ?? false
		// Retrying before the answer can arrive only doubles the traffic.
		if unconfirmed && answering { return sent &+ min(max(Tuning.retryNanos, (smoothedRoundTrip ?? 0) * 3 / 2), Tuning.remoteHeartbeatNanos) }
		return sent &+ (remote != nil ? Tuning.remoteHeartbeatNanos : Tuning.localHeartbeatNanos)
	}

	private func nextTick(now: Tick) -> Tick {
		let due = frameDue(now: now)
		guard let remote else { return due }
		if !canInject { return now }
		return min(due, silenceBase(remote) &+ Tuning.targetSilentReturnNanos &+ 1)
	}
}
