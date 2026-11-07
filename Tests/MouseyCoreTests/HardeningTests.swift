import CoreGraphics
import XCTest
@testable import MouseyCore

final class HardeningTests: XCTestCase {
	func testNoCrossingWhileLockedAndLockingReturns() {
		var rig = Rig()
		rig.cross()
		XCTAssertTrue(rig.isRemote)
		rig.send(.locked(true))
		XCTAssertFalse(rig.isRemote)
		XCTAssertEqual(rig.core.status.lastReturn, .screenLocked)
		rig.ack(after: ms)
		rig.push()
		XCTAssertFalse(rig.isRemote, "someone at the locked keyboard Mac must not reach the other Mac")
		rig.send(.locked(false))
		rig.ack(after: ms)
		rig.push()
		XCTAssertTrue(rig.isRemote)
	}

	func testAnAckFromBeforeTheReturnDoesNotAllowCrossingAgain() {
		var rig = Rig()
		rig.cross()
		let beforeReturn = rig.key(.keyDown(code: 12, isRepeat: false), after: ms).frames.last!
		rig.send(.fault(.panicChord), after: ms)
		rig.send(.ack(Ack(session: 7, seq: beforeReturn.seq, sentNanos: rig.now, nextEventID: 1, appliedMotionSeq: 0, controlled: true, canInject: true, displays: targetScreen.frames)), after: ms)
		rig.push()
		XCTAssertFalse(rig.isRemote, "the target has not seen the return, so a held key would stick")
		rig.ack(after: ms)
		rig.push()
		XCTAssertTrue(rig.isRemote)
	}

	func testRetriesWaitForTheAnswerOnASlowLink() {
		var rig = Rig()
		rig.cross()
		for _ in 0..<40 { rig.ack(after: ms, controlled: true, sent: rig.now - 39 * ms) }
		let sent = rig.motion(1, 0, after: ms, id: 1)
		XCTAssertEqual(sent.frames.count, 1)
		XCTAssertGreaterThan(sent.nextTick, rig.now + 50 * ms, "about 1.5 round trips")
		XCTAssertLessThanOrEqual(sent.nextTick, rig.now + 60 * ms)
		XCTAssertTrue(rig.send(.tick, after: 30 * ms).frames.isEmpty)
		XCTAssertEqual(rig.send(.tick, after: 30 * ms).frames.count, 1)
	}

	func testRetriesStayFastOnAFastLink() {
		var rig = Rig()
		rig.cross()
		rig.ack(after: ms, controlled: true)
		XCTAssertEqual(rig.motion(1, 0, after: ms, id: 1).nextTick, rig.now + Tuning.retryNanos)
	}

	func testMoreEventsFitAfterCompression() {
		var rig = Rig()
		rig.cross()
		var last: Frame?
		for i in 0..<6 {
			let scroll = payload(.scroll, 2, 0, id: UInt32(i)) + Data(repeating: UInt8(i), count: 470)
			last = rig.send(.grabbed(.scroll(phase: 2, momentumPhase: 0), bytes: scroll, flags: 0), after: ms).frames.last
		}
		XCTAssertEqual(last?.events.count, 6, "at 470 bytes, only 2 would fit without compression")
		XCTAssertLessThanOrEqual(Wire.encode(last!).count, Wire.maxDatagram)
	}

	func testAFrameExactlyHalfTheCounterAwayCannotTrap() {
		var inbox = Inbox()
		inbox.reset(next: 0)
		XCTAssertEqual(inbox.accept(firstID: 0x8000_0000, events: [WireEvent(x: 0, y: 0, motionSeq: 0, bytes: Data())]), [])
	}

	func testStoppingReleasesWhatIsHeld() {
		var target = TargetCore(displays: targetScreen, classify: classify)
		let down = WireEvent(x: 1, y: 1, motionSeq: 0, bytes: payload(.keyDown, 12, id: 1))
		let frame = Frame(session: 1, seq: 1, sentNanos: 1, isRemote: true, x: 1, y: 1, motionSeq: 0, motion: nil, firstEventID: 0, events: [down], repeats: [])
		_ = target.receive(frame, canInject: true, now: second)
		XCTAssertEqual(target.releaseAll(), [.releaseKey(code: 12)])
		XCTAssertEqual(target.releaseAll(), [])
		XCTAssertFalse(target.status.controlled)
	}

	func testLatencySummaryReadsInMilliseconds() {
		XCTAssertEqual(latencySummary((1...100).map { UInt64($0) * 1_000_000 }), "p50 51.00 p90 91.00 p99 100.00 max 100.00 ms")
		XCTAssertEqual(latencySummary([]), "no samples")
	}
}
