/// Which app gets focus back when capture ends, after this app took focus because of secure input. Only the first
/// sighting counts, because by a second one this app has focus itself.
public struct FocusToRestore<Application> {
	private var application: Application?

	public init() {}

	public mutating func secureInputSeen(frontmost: Application?) {
		if application == nil { application = frontmost }
	}

	public mutating func captureEnded() -> Application? {
		defer { application = nil }
		return application
	}
}
