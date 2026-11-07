import CoreGraphics
import Foundation
import MouseyCore

/// What the grab tap does with one event.
enum Action: Equatable {
	case motion(dx: Double, dy: Double)
	case input(EventClass)
	/// Forward nothing and return nil, so the keyboard Mac never sees it either.
	case consume
	/// Leave it for the keyboard Mac.
	case pass
}

/// The only place that knows raw event type numbers and field numbers.
enum Classify {
	/// Fields with no public name. Named here so `Replay` never sees a number.
	enum Field {
		static let gestureSubtype = CGEventField(rawValue: 110)!
		static let gesturePhase = CGEventField(rawValue: 132)!
		static let gesturePhase2 = CGEventField(rawValue: 134)!
		/// Always in `mach_absolute_time` ticks, whatever unit `timestamp` uses.
		static let timestampTicks = CGEventField(rawValue: 169)!
	}

	enum Clock { case machTicks, uptimeRawNanos }

	static let motionTypes: Set<UInt32> = [5, 6, 7, 27]
	static let motionMask: CGEventMask = motionTypes.reduce(0) { $0 | (1 << CGEventMask($1)) }
	static let tapDisabledTypes: Set<UInt32> = [CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue]
	private static let passTypes: Set<UInt32> = [0, 13, 15, 16, 17]
	private static let rawTouchSubtype: Int64 = 0

	/// Key code of a modifier to its device-dependent flag bit. Caps Lock (57) is absent on purpose.
	private static let modifierMasks: [Int64: UInt64] = [
		59: 0x1, 62: 0x2000, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 63: 0x800000,
	]

	static func action(for event: CGEvent) -> Action {
		let type = event.type.rawValue
		switch type {
		case 5, 6, 7, 27:
			return .motion(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
		case 10:
			return .input(.keyDown(code: keyCode(event), isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
		case 11:
			return .input(.keyUp(code: keyCode(event)))
		case 12:
			let code = event.getIntegerValueField(.keyboardEventKeycode)
			guard let mask = modifierMasks[code] else { return .input(.other) }
			return .input(.modifier(code: keyCode(event), isDown: event.flags.rawValue & mask != 0))
		case 1, 3, 25:
			return .input(.button(index: Int(event.getIntegerValueField(.mouseEventButtonNumber)), isDown: true))
		case 2, 4, 26:
			return .input(.button(index: Int(event.getIntegerValueField(.mouseEventButtonNumber)), isDown: false))
		case 22:
			return .input(.scroll(
				phase: Int(event.getIntegerValueField(.scrollWheelEventScrollPhase)),
				momentumPhase: Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))))
		case 29, 30:
			let subtype = event.getIntegerValueField(Field.gestureSubtype)
			if type == 29 && subtype == rawTouchSubtype { return .consume }
			return .input(.gesture(phase: Int(event.getIntegerValueField(Field.gesturePhase)), kind: Int(type) << 8 | Int(subtype)))
		case _ where passTypes.contains(type) || tapDisabledTypes.contains(type):
			return .pass
		default:
			return .input(.other)
		}
	}

	/// The trust boundary for payloads on the target. nil when the bytes do not rebuild into an event.
	static func eventClass(for bytes: Data) -> EventClass? {
		guard let event = CGEvent(withDataAllocator: nil, data: bytes as CFData) else { return nil }
		switch action(for: event) {
		case .motion: return .other
		case .input(let event): return event
		case .consume, .pass: return nil
		}
	}

	static func clock(for event: CGEvent) -> Clock {
		[29, 30].contains(event.type.rawValue) ? .uptimeRawNanos : .machTicks
	}

	private static func keyCode(_ event: CGEvent) -> UInt16 {
		UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
	}
}
