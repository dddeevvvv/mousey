import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import MouseyCore

/// The only place that posts events.
enum Replay {
	/// `--selftest` replaces this to capture what would be posted.
	static var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

	static let deltaFields: [CGEventField] = [
		.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis1,
		.scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
	]
	private static let phaseEnded: Int64 = 4
	private static let momentumEnded: Int64 = 3
	private static let gestureCancelled: Int64 = 8

	static func perform(_ command: TargetCommand) {
		switch command {
		case .post(let bytes, let at), .postMotion(let bytes, let at):
			guard let e = rebuilt(bytes, at: at) else { return }
			post(e)
		case .releaseKey(let code):
			guard let e = CGEvent(keyboardEventSource: source(), virtualKey: code, keyDown: false) else { return }
			post(e)
		case .releaseModifier(let code):
			guard let e = CGEvent(keyboardEventSource: source(), virtualKey: code, keyDown: false) else { return }
			e.type = .flagsChanged
			e.flags = []
			post(e)
		case .releaseButton(let index, let at):
			let type: CGEventType = index == 0 ? .leftMouseUp : index == 1 ? .rightMouseUp : .otherMouseUp
			guard let e = CGEvent(mouseEventSource: source(), mouseType: type, mouseCursorPosition: at, mouseButton: CGMouseButton(rawValue: UInt32(clamping: index)) ?? .center) else { return }
			e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(index))
			post(e)
		case .endScroll(let bytes, let at):
			guard let e = rebuilt(bytes, at: at) else { return }
			for f in deltaFields {
				e.setIntegerValueField(f, value: 0)
				e.setDoubleValueField(f, value: 0)
			}
			if ScrollPhases.isOpen(momentumPhase: Int(e.getIntegerValueField(.scrollWheelEventMomentumPhase))) {
				e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumEnded)
			} else {
				e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseEnded)
			}
			post(e)
		case .endGesture(let bytes, let at):
			guard let e = rebuilt(bytes, at: at) else { return }
			e.setIntegerValueField(Classify.Field.gesturePhase, value: gestureCancelled)
			if e.getIntegerValueField(Classify.Field.gesturePhase2) != 0 { e.setIntegerValueField(Classify.Field.gesturePhase2, value: gestureCancelled) }
			post(e)
		case .declareUserActivity:
			// Passing the same id back renews one assertion instead of adding another each second.
			IOPMAssertionDeclareUserActivity("Mousey input" as CFString, kIOPMUserActiveLocal, &activityAssertion)
		}
	}

	private static var activityAssertion: IOPMAssertionID = 0

	/// Converges a crash in the middle of a hold. Never prompts.
	static func releaseEverythingAtStartup() {
		guard CGPreflightPostEventAccess() else { return }
		let at = CGEvent(source: nil)?.location ?? .zero
		perform(.releaseModifier(code: 56))
		for index in 0..<3 { perform(.releaseButton(index: index, at: at)) }
	}

	/// Rebuilds the bytes, moves the event to `at`, and gives it the current time in its own unit.
	static func rebuilt(_ bytes: Data, at: CGPoint) -> CGEvent? {
		guard let e = CGEvent(withDataAllocator: nil, data: bytes as CFData) else { return nil }
		e.location = at
		switch Classify.clock(for: e) {
		case .machTicks: e.timestamp = mach_absolute_time()
		case .uptimeRawNanos: e.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
		}
		if e.getIntegerValueField(Classify.Field.timestampTicks) != 0 {
			e.setIntegerValueField(Classify.Field.timestampTicks, value: Int64(bitPattern: mach_absolute_time()))
		}
		return e
	}

	private static func source() -> CGEventSource? { CGEventSource(stateID: .privateState) }
}
