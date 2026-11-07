public enum EventClass: Equatable, Sendable {
	case keyDown(code: UInt16, isRepeat: Bool)
	case keyUp(code: UInt16)
	/// `flagsChanged`. `isDown` comes from the device-dependent flag bit for this key code. Caps Lock is `.other`.
	case modifier(code: UInt16, isDown: Bool)
	case button(index: Int, isDown: Bool)
	/// Raw values of the phase fields. See `ScrollPhases`.
	case scroll(phase: Int, momentumPhase: Int)
	/// `kind` separates streams that can be open at once, such as the two event types a dock swipe arrives in.
	case gesture(phase: Int, kind: Int)
	case other
}

/// Whether a scroll or gesture stream is still open, from its raw phase values. One table, used by `TargetCore`.
public enum ScrollPhases {
	public static func isOpen(phase: Int) -> Bool { [1, 2, 128].contains(phase) }
	public static func isOpen(momentumPhase: Int) -> Bool { [1, 2].contains(momentumPhase) }
}
