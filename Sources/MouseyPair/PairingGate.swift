import Foundation

/// How many strangers the controlled Mac will talk to while pairing.
///
/// The controlled Mac shows a code only after the other side reveals its key, so someone can try keys against it and
/// walk away from every one that would give the wrong code, with nothing on screen. Limiting the tries is what keeps
/// that from working: 10 tries against a 6-digit code is one chance in 100,000, and then a person has to press Try Again.
public struct PairingGate: Sendable {
	public static let minimumGap: TimeInterval = 2
	public static let maximumAttempts = 10

	public private(set) var attempts = 0
	private var last: Date?

	public init() {}

	public var isExhausted: Bool { attempts >= Self.maximumAttempts }

	public mutating func allow(now: Date) -> Bool {
		guard !isExhausted else { return false }
		if let last, now.timeIntervalSince(last) < Self.minimumGap { return false }
		last = now
		attempts += 1
		return true
	}
}
