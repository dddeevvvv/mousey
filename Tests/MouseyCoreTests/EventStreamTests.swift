import XCTest
import MouseyCore
@testable import MouseyCore

final class EventStreamTests: XCTestCase {
	private func event(_ i: UInt32, size: Int = 10) -> WireEvent {
		WireEvent(x: 0, y: 0, motionSeq: 0, bytes: payload(.keyDown, UInt8(truncatingIfNeeded: i), id: i) + Data(repeating: 0, count: size))
	}

	func testOutboxKeepsEventsUntilAckedOldestFirst() {
		var outbox = Outbox()
		for i in 0..<5 { XCTAssertTrue(outbox.append(event(UInt32(i)))) }
		XCTAssertEqual(outbox.pending(budget: .max).events.map { payloadID($0.bytes) }, [0, 1, 2, 3, 4])
		outbox.acknowledge(next: 3)
		let p = outbox.pending(budget: .max)
		XCTAssertEqual(p.firstID, 3)
		XCTAssertEqual(p.events.map { payloadID($0.bytes) }, [3, 4])
		outbox.acknowledge(next: 3)
		outbox.acknowledge(next: 1)
		XCTAssertEqual(outbox.pending(budget: .max).firstID, 3, "an old or repeated ack changes nothing")
	}

	func testOutboxRefusesTheEventPastCapacity() {
		var outbox = Outbox()
		for i in 0..<Tuning.outboxCapacity { XCTAssertTrue(outbox.append(event(UInt32(i)))) }
		XCTAssertFalse(outbox.append(event(99)))
		outbox.acknowledge(next: 1)
		XCTAssertTrue(outbox.append(event(99)))
	}

	func testOutboxBudgetTakesAContiguousRunButAlwaysTheOldest() {
		var outbox = Outbox()
		_ = outbox.append(event(0, size: 500))
		_ = outbox.append(event(1, size: 10))
		_ = outbox.append(event(2, size: 10))
		XCTAssertEqual(outbox.pending(budget: 100).events.count, 1, "the oldest alone exceeds the budget and still goes")
		outbox.acknowledge(next: 1)
		let small = Wire.encodedSize(of: event(1, size: 10))
		XCTAssertEqual(outbox.pending(budget: small).events.map { payloadID($0.bytes) }, [1], "the run stops where the next does not fit")
		XCTAssertEqual(outbox.pending(budget: 2 * small).events.count, 2)
	}

	func testClearAbandonsEventsAndTheIDsKeepIncreasing() {
		var outbox = Outbox()
		for i in 0..<4 { _ = outbox.append(event(UInt32(i))) }
		outbox.acknowledge(next: 1)
		outbox.clear()
		XCTAssertTrue(outbox.isEmpty)
		XCTAssertEqual(outbox.pending(budget: .max).firstID, 4)
		_ = outbox.append(event(7))
		XCTAssertEqual(outbox.pending(budget: .max).firstID, 4, "a new event takes the next ID, not a reused one")
	}

	func testOutboxIDsWrap() {
		var outbox = Outbox(firstID: UInt32.max - 1)
		for i in 0..<4 { _ = outbox.append(event(UInt32(i))) }
		outbox.acknowledge(next: 1)
		XCTAssertEqual(outbox.pending(budget: .max).events.map { payloadID($0.bytes) }, [3], "an ack across the wrap drops the first three")
		XCTAssertEqual(outbox.pending(budget: .max).firstID, 1)
	}

	func testInboxDeliversEachEventOnceInOrder() {
		var inbox = Inbox()
		inbox.reset(next: 10)
		let run = (10..<14).map { event($0) }
		XCTAssertEqual(inbox.accept(firstID: 10, events: Array(run[0..<2])).map { payloadID($0.bytes) }, [10, 11])
		XCTAssertEqual(inbox.accept(firstID: 10, events: run).map { payloadID($0.bytes) }, [12, 13])
		XCTAssertEqual(inbox.accept(firstID: 10, events: run), [])
		XCTAssertEqual(inbox.next, 14)
	}

	func testInboxJumpsOverAnAbandonedGap() {
		var inbox = Inbox()
		inbox.reset(next: 3)
		XCTAssertEqual(inbox.accept(firstID: 8, events: [event(8), event(9)]).map { payloadID($0.bytes) }, [8, 9])
		XCTAssertEqual(inbox.next, 10)
		XCTAssertEqual(inbox.accept(firstID: 20, events: []), [])
		XCTAssertEqual(inbox.next, 20, "a frame with no events still moves next")
	}

	func testInboxWrapsAroundTheIDSpace() {
		var inbox = Inbox()
		inbox.reset(next: UInt32.max - 1)
		let run = [UInt32.max - 1, UInt32.max, 0, 1].map { event($0) }
		XCTAssertEqual(inbox.accept(firstID: UInt32.max - 1, events: Array(run[0..<3])).count, 3)
		XCTAssertEqual(inbox.next, 1)
		XCTAssertEqual(inbox.accept(firstID: UInt32.max - 1, events: run).map { payloadID($0.bytes) }, [1])
		XCTAssertEqual(inbox.next, 2)
		XCTAssertEqual(inbox.accept(firstID: 5, events: []), [])
		XCTAssertEqual(inbox.next, 5, "a jump across zero is forward")
	}

	func testSerialComparison() {
		XCTAssertTrue(isNewer(1, than: 0))
		XCTAssertFalse(isNewer(0, than: 0))
		XCTAssertTrue(isNewer(0, than: UInt32.max))
		XCTAssertFalse(isNewer(UInt32.max, than: 0))
		XCTAssertTrue(isNewer(5, than: UInt32.max - 5))
		XCTAssertFalse(isNewer(UInt32.max / 2 + 2, than: 0), "more than half the space ahead counts as behind")
	}

	func testScrollPhaseTable() {
		XCTAssertEqual([0, 1, 2, 4, 8, 128].map(ScrollPhases.isOpen(phase:)), [false, true, true, false, false, true])
		XCTAssertEqual([0, 1, 2, 3].map(ScrollPhases.isOpen(momentumPhase:)), [false, true, true, false])
	}
}
