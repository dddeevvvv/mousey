import Foundation

/// A line for the log, from timing samples in nanoseconds.
public func latencySummary(_ nanos: [UInt64]) -> String {
	guard !nanos.isEmpty else { return "no samples" }
	let sorted = nanos.sorted()
	func at(_ q: Double) -> String { String(format: "%.2f", Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) / 1e6) }
	return "p50 \(at(0.5)) p90 \(at(0.9)) p99 \(at(0.99)) max \(at(1)) ms"
}
