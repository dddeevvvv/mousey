import Foundation

/// Serial-number comparison, so counters may wrap.
func isNewer(_ a: UInt32, than b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }

/// Controller side. Keeps events until acked, and picks which fit in the next frame. Oldest first, always.
public struct Outbox: Sendable {
	private var events: [WireEvent] = []
	private var firstID: UInt32

	public init() { firstID = 0 }
	init(firstID: UInt32) { self.firstID = firstID }

	/// Returns false when full (`Tuning.outboxCapacity`). The caller treats that as a fault.
	public mutating func append(_ event: WireEvent) -> Bool {
		guard events.count < Tuning.outboxCapacity else { return false }
		events.append(event)
		return true
	}

	public mutating func acknowledge(next: UInt32) {
		let confirmed = min(Int(max(Int32(bitPattern: next &- firstID), 0)), events.count)
		events.removeFirst(confirmed)
		firstID &+= UInt32(confirmed)
	}

	/// The contiguous run from the oldest unacked event that fits in `budget` bytes. Always includes the oldest,
	/// even if it alone exceeds the budget, so the stream cannot wedge. `firstID` is valid when the run is empty.
	public func pending(budget: Int) -> (firstID: UInt32, events: [WireEvent]) {
		var run: [WireEvent] = []
		var used = 0
		for e in events {
			let size = Wire.encodedSize(of: e)
			if !run.isEmpty && used + size > budget { break }
			run.append(e)
			used += size
		}
		return (firstID, run)
	}

	/// Drops every unconfirmed event. IDs keep increasing, so the target sees a jump in `firstEventID`.
	public mutating func clear() {
		firstID &+= UInt32(events.count)
		events.removeAll()
	}

	public var isEmpty: Bool { events.isEmpty }
	public var count: Int { events.count }
}

/// Target side. Delivers each event exactly once and in order. Frames are already known to be newer than the last.
public struct Inbox: Sendable {
	public private(set) var next: UInt32 = 0

	public init() {}

	public mutating func reset(next: UInt32) { self.next = next }

	/// The events in this frame not yet delivered. If `firstID` is past `next`, the controller abandoned the gap,
	/// so `next` jumps forward. Uses serial-number comparison, so IDs may wrap.
	public mutating func accept(firstID: UInt32, events: [WireEvent]) -> [WireEvent] {
		if isNewer(firstID, than: next) { next = firstID }
		let delivered = Int(Int32(bitPattern: next &- firstID))
		guard delivered >= 0, delivered < events.count else { return [] }
		let fresh = Array(events[delivered...])
		next &+= UInt32(fresh.count)
		return fresh
	}
}
