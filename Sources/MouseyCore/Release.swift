import Foundation

private let asciiDigits: ClosedRange<UInt8> = 48...57
private let digitsInAPart = 1...6
private let mostParts = 4
private let secondsBetweenChecks: TimeInterval = 24 * 3600

public func newerRelease(tag: String, current: String) -> String? {
	guard let latest = releaseNumbers(tag), let running = releaseNumbers(current), running.lexicographicallyPrecedes(latest) else { return nil }
	return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
}

private func releaseNumbers(_ text: String) -> [Int]? {
	let digits = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
	let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
	guard parts.count <= mostParts, parts.allSatisfy({ part in digitsInAPart.contains(part.utf8.count) && part.utf8.allSatisfy(asciiDigits.contains) }) else { return nil }
	var numbers = parts.compactMap { Int($0) }
	while numbers.last == 0 { numbers.removeLast() }
	return numbers
}

public struct UpdateState: Equatable {
	public var enabled: Bool
	public var lastCheck: Date?
	public var latestTag: String?

	public init(enabled: Bool, lastCheck: Date?, latestTag: String?) {
		self.enabled = enabled
		self.lastCheck = lastCheck
		self.latestTag = latestTag
	}

	public mutating func record(tag: String) {
		if releaseNumbers(tag) != nil { latestTag = tag }
	}

	public func notice(current: String) -> String? {
		guard enabled, let latestTag else { return nil }
		return newerRelease(tag: latestTag, current: current)
	}

	public mutating func claimDailyCheck(now: Date) -> Bool {
		guard enabled else { return false }
		if let lastCheck, abs(now.timeIntervalSince(lastCheck)) < secondsBetweenChecks { return false }
		lastCheck = now
		return true
	}
}
