import CoreGraphics
import XCTest
import MouseyCore

/// Every way out of remote must end with `.endCapture` exactly once, and repeating the cause must be harmless.
final class LockoutTests: XCTestCase {
	private func remoteRig() -> Rig {
		var rig = Rig()
		rig.cross()
		rig.ack(controlled: true)
		return rig
	}

	private func assertReturns(_ reason: ReturnReason, file: StaticString = #filePath, line: UInt = #line, cause: (inout Rig) -> [ControllerOutput]) {
		var rig = remoteRig()
		let first = cause(&rig)
		XCTAssertEqual(first.flatMap(\.endCaptures).count, 1, "\(reason) ends capture once", file: file, line: line)
		XCTAssertFalse(rig.isRemote, "\(reason)", file: file, line: line)
		XCTAssertEqual(rig.core.status.lastReturn, reason, file: file, line: line)
		XCTAssertEqual(first.flatMap(\.frames).last?.isRemote, false, "\(reason) tells the target", file: file, line: line)
		let again = cause(&rig)
		XCTAssertEqual(again.flatMap(\.endCaptures), [], "\(reason) repeated", file: file, line: line)
		XCTAssertEqual(rig.core.status.lastReturn, reason, file: file, line: line)
	}

	func testFaults() {
		for reason in [ReturnReason.socketError, .tapDisabled, .sleep, .screenLocked, .sessionChanged, .terminating, .disabled, .targetSilent, .outboxFull] {
			assertReturns(reason) { [$0.send(.fault(reason), after: 10 * ms)] }
		}
	}

	func testTargetEdge() {
		assertReturns(.targetEdge) { [$0.motion(-50, 0, after: 4 * ms), $0.motion(-50, 0, after: 90 * ms)] }
	}

	func testPanicChord() {
		assertReturns(.panicChord) { [$0.key(.keyDown(code: 53, isRepeat: false), flags: 0x1C0000, after: 4 * ms)] }
	}

	func testSilenceOnTicks() {
		assertReturns(.targetSilent) { rig in
			(0..<12).map { _ in rig.send(.tick, after: 100 * ms) }
		}
	}

	func testTargetCannotInject() {
		assertReturns(.targetCannotInject) { rig in
			[rig.ack(after: 10 * ms, canInject: false), rig.send(.tick, after: ms)]
		}
	}

	func testClockGap() {
		assertReturns(.clockGap) { rig in [rig.ack(after: 10 * ms, controlled: true), rig.send(.tick, after: 1_500 * ms)] }
	}

	func testOutboxFull() {
		assertReturns(.outboxFull) { rig in
			(0..<Tuning.outboxCapacity + 1).map { i in
				rig.send(.grabbed(.button(index: i, isDown: true), bytes: payload(.buttonDown, UInt8(truncatingIfNeeded: i), id: UInt32(i)), flags: 0), after: ms)
			}
		}
	}

	func testFaultWhileLocalChangesNothingAndEmitsNothing() {
		var rig = Rig()
		rig.ack()
		let out = rig.send(.fault(.sleep))
		XCTAssertEqual(out.endCaptures, [])
		XCTAssertNil(rig.core.status.lastReturn)
	}

	func testReturnReasonOfTheFirstCauseIsKept() {
		var rig = remoteRig()
		rig.send(.fault(.sleep))
		rig.send(.fault(.screenLocked))
		XCTAssertEqual(rig.core.status.lastReturn, .sleep)
	}

	// MARK: Liveness

	func testEnteringDoesNotTripSilenceWhenTheLastAckIsOldButInsideTheOnlineWindow() {
		var rig = Rig()
		rig.ack()
		rig.send(.tick, after: 2_300 * ms)
		rig.push()
		XCTAssertTrue(rig.isRemote)
		for _ in 0..<8 { rig.send(.tick, after: 100 * ms) }
		XCTAssertTrue(rig.isRemote, "800 ms after crossing, over 3 s after the ack")
		rig.send(.tick, after: 100 * ms)
		let out = rig.send(.tick, after: 101 * ms)
		XCTAssertEqual(out.endCaptures.count, 1, "silence counts from the crossing, so it trips just over a second after it")
	}

	func testContinuousMotionWithNoAcksStillReturnsWithinTheLimitAndNoTickIsEverSent() {
		var rig = Rig()
		rig.cross()
		let crossedAt = rig.now
		var returnedAfter: Tick?
		var triggering: ControllerOutput?
		while returnedAfter == nil && rig.now < crossedAt + 3 * second {
			let out = rig.motion(1, 0, after: 8 * ms)
			if !out.endCaptures.isEmpty { returnedAfter = rig.now - crossedAt; triggering = out }
		}
		XCTAssertNotNil(returnedAfter)
		XCTAssertLessThanOrEqual(returnedAfter ?? .max, Tuning.targetSilentReturnNanos + 8 * ms)
		XCTAssertGreaterThan(returnedAfter ?? 0, Tuning.targetSilentReturnNanos)
		XCTAssertEqual(triggering?.disposition, .pass, "the motion that found the link dead is not swallowed")
		XCTAssertEqual(rig.core.status.lastReturn, .targetSilent)
	}

	func testContinuousMotionWithAcksNeverReturns() {
		var rig = Rig()
		rig.cross()
		for i in 0..<400 {
			rig.motion(0.1, 0, after: 8 * ms)
			if i % 20 == 0 { rig.ack(controlled: true) }
		}
		XCTAssertTrue(rig.isRemote)
	}

	func testGrabbedEventAfterTheLimitPassesToTheLocalMac() {
		var rig = remoteRig()
		for _ in 0..<10 { rig.send(.tick, after: 100 * ms) }
		let out = rig.key(.keyDown(code: 1, isRepeat: false), after: 100 * ms)
		XCTAssertEqual(out.disposition, .pass)
		XCTAssertEqual(out.endCaptures.count, 1)
		XCTAssertEqual(out.frames.last?.events, [], "it was not forwarded to a target that stopped answering")
		XCTAssertEqual(rig.core.status.lastReturn, .targetSilent)
	}

	func testClockGapBeatsSilenceAndReturns() {
		var rig = remoteRig()
		let out = rig.send(.fault(.disabled), after: 5 * second)
		XCTAssertEqual(out.endCaptures.count, 1)
		XCTAssertEqual(rig.core.status.lastReturn, .clockGap)
	}

	func testClockGapWhileLocalIsNothing() {
		var rig = Rig()
		rig.ack()
		let out = rig.send(.tick, after: 30 * second)
		XCTAssertEqual(out.endCaptures, [])
		XCTAssertNil(rig.core.status.lastReturn)
	}

	func testAckThatRevokesInjectionReturnsOnTheNextEventAndAsksForItImmediately() {
		var rig = remoteRig()
		let out = rig.ack(after: 10 * ms, controlled: true, canInject: false)
		XCTAssertEqual(out.nextTick, rig.now, "do not wait for the heartbeat")
		let next = rig.motion(1, 0, after: ms)
		XCTAssertEqual(next.disposition, .pass)
		XCTAssertEqual(next.endCaptures.count, 1)
		XCTAssertEqual(rig.core.status.lastReturn, .targetCannotInject)
	}

	func testSilenceTripsFromTheLaterOfAckAndCrossing() {
		var rig = remoteRig()
		for _ in 0..<9 { rig.send(.tick, after: 100 * ms) }
		rig.ack(controlled: true)
		for _ in 0..<9 { rig.send(.tick, after: 100 * ms) }
		XCTAssertTrue(rig.isRemote, "the ack 900 ms ago restarted the clock")
		rig.send(.tick, after: 100 * ms)
		XCTAssertEqual(rig.send(.tick, after: ms).endCaptures.count, 1)
	}

	func testReturnedControllerCanCrossAgainOnceTheTargetAnswers() {
		var rig = remoteRig()
		rig.send(.fault(.disabled))
		rig.ack(after: 100 * ms)
		rig.push()
		XCTAssertTrue(rig.isRemote)
	}
}
