import Foundation
import CoreGraphics

public enum TargetCommand: Equatable, Sendable {
	/// Rebuild these bytes, set the location, and post. A motion post may be collapsed by `coalesce`.
	case postMotion(bytes: Data, at: CGPoint)
	case post(bytes: Data, at: CGPoint)
	case releaseKey(code: UInt16)
	case releaseModifier(code: UInt16)
	case releaseButton(index: Int, at: CGPoint)
	/// `bytes` is the last event of the open stream. The shell rebuilds it and changes its phase, so the receiver sees
	/// the same stream end. Otherwise a swipe cut off by an outage could leave Mission Control half open.
	case endScroll(bytes: Data, at: CGPoint)
	case endGesture(bytes: Data, at: CGPoint)
	case declareUserActivity
}

public struct TargetStatus: Equatable, Sendable {
	public var controlled: Bool
	public var controllerSeen: Bool
	public var droppedEvents: Int
}

/// What the target has pressed and not yet released.
private struct Held {
	var keys = Set<UInt16>()
	var modifiers = Set<UInt16>()
	var buttons = Set<Int>()
	var openScroll: Data?
	var openGestures: [Int: Data] = [:]

	mutating func note(_ event: EventClass, bytes: Data) {
		switch event {
		case .keyDown(let code, false): keys.insert(code)
		case .keyUp(let code): keys.remove(code)
		case .modifier(let code, let isDown):
			if isDown { modifiers.insert(code) } else { modifiers.remove(code) }
		case .button(let index, let isDown):
			if isDown { buttons.insert(index) } else { buttons.remove(index) }
		case .scroll(let phase, let momentum):
			openScroll = ScrollPhases.isOpen(phase: phase) || ScrollPhases.isOpen(momentumPhase: momentum) ? bytes : nil
		case .gesture(let phase, let kind):
			openGestures[kind] = ScrollPhases.isOpen(phase: phase) ? bytes : nil
		case .keyDown, .other:
			break
		}
	}

	/// Gesture and scroll first, then buttons, keys, and modifiers.
	mutating func releaseAll(at p: CGPoint) -> [TargetCommand] {
		var out: [TargetCommand] = []
		out += openGestures.sorted { $0.key < $1.key }.map { .endGesture(bytes: $0.value, at: p) }
		if let openScroll { out.append(.endScroll(bytes: openScroll, at: p)) }
		out += buttons.sorted().map { .releaseButton(index: $0, at: p) }
		out += keys.sorted().map { .releaseKey(code: $0) }
		out += modifiers.sorted().map { .releaseModifier(code: $0) }
		self = Held()
		return out
	}
}

/// Invariants:
/// A frame whose `seq` is not newer than the last accepted, within a session, changes nothing.
/// `isRemote` false, a new `session`, and `targetSilentReleaseNanos` of silence each run `releaseAll`, which is
/// idempotent. Silence ends `controlled`, and a later `isRemote` frame resumes it.
/// `classify` is the trust boundary for payloads. nil means the payload did not rebuild, so the event is dropped and
/// counted, and its ID still advances.
/// A repeat is posted only while its key is held.
/// Capture order: for each newly delivered event, the latest motion is posted first if its `motionSeq` is at or below
/// the event's and has not been applied. Then the event. Then any remaining motion. An event's own stamp also marks
/// motion up to that value as applied, so no older motion is posted after it.
public struct TargetCore {
	private var displays: Displays
	private let classify: (Data) -> EventClass?
	private var session: UInt32?
	private var lastSeq: UInt32?
	private var inbox = Inbox()
	private var appliedMotion: UInt32 = 0
	private var held = Held()
	private var position = CGPoint.zero
	private var controlled = false
	private var controllerSeen = false
	private var lastFrame: Tick = 0
	private var lastActivity: Tick?
	private var dropped = 0

	public init(displays: Displays, classify: @escaping (Data) -> EventClass?) {
		self.displays = displays
		self.classify = classify
	}

	public mutating func receive(_ frame: Frame, canInject: Bool, now: Tick) -> (commands: [TargetCommand], ack: Ack) {
		var out: [TargetCommand] = []
		if session != frame.session {
			out += held.releaseAll(at: position)
			session = frame.session
			inbox.reset(next: frame.firstEventID)
			lastSeq = nil
			appliedMotion = 0
		}
		if let last = lastSeq, !isNewer(frame.seq, than: last) { return (out, ack(for: frame, canInject: canInject)) }
		lastSeq = frame.seq
		lastFrame = now
		controllerSeen = true

		guard frame.isRemote && canInject else {
			out += held.releaseAll(at: position)
			controlled = false
			_ = inbox.accept(firstID: frame.firstEventID, events: [])
			return (out, ack(for: frame, canInject: canInject))
		}
		controlled = true
		var posted: [TargetCommand] = []
		replay(frame, into: &posted)
		for repeated in frame.repeats { postRepeat(repeated, into: &posted) }
		if !posted.isEmpty, lastActivity.map({ elapsed(now, since: $0) >= Tuning.userActivityNanos }) ?? true {
			lastActivity = now
			out.append(.declareUserActivity)
		}
		return (out + posted, ack(for: frame, canInject: canInject))
	}

	/// Call about every 200 ms. Releases held input after silence.
	public mutating func tick(now: Tick) -> [TargetCommand] {
		guard controllerSeen, elapsed(now, since: lastFrame) >= Tuning.targetSilentReleaseNanos else { return [] }
		controlled = false
		return held.releaseAll(at: position)
	}

	/// For stopping the receiver, so a quit in the middle of a hold leaves nothing pressed.
	public mutating func releaseAll() -> [TargetCommand] {
		controlled = false
		return held.releaseAll(at: position)
	}

	public mutating func setDisplays(_ displays: Displays) { self.displays = displays }

	public var status: TargetStatus {
		TargetStatus(controlled: controlled, controllerSeen: controllerSeen, droppedEvents: dropped)
	}

	private mutating func replay(_ frame: Frame, into out: inout [TargetCommand]) {
		var motionPending = frame.motion != nil && isNewer(frame.motionSeq, than: appliedMotion)
		for event in inbox.accept(firstID: frame.firstEventID, events: frame.events) {
			let at = CGPoint(x: event.x, y: event.y)
			if motionPending, !isNewer(frame.motionSeq, than: event.motionSeq) {
				postMotion(frame.motion, at: at, into: &out)
				appliedMotion = frame.motionSeq
				motionPending = false
			}
			postEvent(event.bytes, at: at, into: &out)
			if isNewer(event.motionSeq, than: appliedMotion) { appliedMotion = event.motionSeq }
		}
		if motionPending {
			postMotion(frame.motion, at: CGPoint(x: frame.x, y: frame.y), into: &out)
			appliedMotion = frame.motionSeq
		}
	}

	private mutating func postMotion(_ bytes: Data?, at: CGPoint, into out: inout [TargetCommand]) {
		guard let bytes, classify(bytes) != nil else { return dropped += 1 }
		position = at
		out.append(.postMotion(bytes: bytes, at: at))
	}

	private mutating func postEvent(_ bytes: Data, at: CGPoint, into out: inout [TargetCommand]) {
		guard let event = classify(bytes) else { return dropped += 1 }
		if case .keyDown(let code, true) = event, !held.keys.contains(code) { return }
		held.note(event, bytes: bytes)
		position = at
		out.append(.post(bytes: bytes, at: at))
	}

	private mutating func postRepeat(_ bytes: Data, into out: inout [TargetCommand]) {
		guard let event = classify(bytes) else { return dropped += 1 }
		if case .keyDown(let code, _) = event, held.keys.contains(code) { out.append(.post(bytes: bytes, at: position)) }
	}

	private func ack(for frame: Frame, canInject: Bool) -> Ack {
		Ack(
			session: frame.session, seq: frame.seq, sentNanos: frame.sentNanos, nextEventID: inbox.next,
			appliedMotionSeq: appliedMotion, controlled: controlled, canInject: canInject, displays: Array(displays.frames.prefix(8)))
	}
}

/// Within a run of `.postMotion`, only the last survives. Order against every other command is preserved.
public func coalesce(_ commands: [TargetCommand]) -> [TargetCommand] {
	var out: [TargetCommand] = []
	for command in commands {
		if case .postMotion = command, case .postMotion? = out.last { out[out.count - 1] = command } else { out.append(command) }
	}
	return out
}
