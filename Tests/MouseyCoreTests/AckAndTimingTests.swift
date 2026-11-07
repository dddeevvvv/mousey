import CoreGraphics
import XCTest
import MouseyCore

final class AckAndTimingTests: XCTestCase {
	func testAckForAnotherSessionIsIgnored() {
		var rig = Rig()
		let foreign = Ack(session: 99, seq: 1, sentNanos: 0, nextEventID: 0, appliedMotionSeq: 0, controlled: false, canInject: true, displays: targetScreen.frames)
		let out = rig.send(.ack(foreign))
		XCTAssertEqual(out.roundTrips, [])
		XCTAssertFalse(rig.core.status.targetOnline)
		rig.push(points: 40, steps: 4)
		XCTAssertFalse(rig.isRemote)
	}

	func testAckSetsOnlineStateAndRoundTrip() {
		var rig = Rig()
		let out = rig.ack(after: 12 * ms, sent: rig.now + 5 * ms)
		XCTAssertEqual(out.roundTrips, [7 * ms])
		XCTAssertTrue(rig.core.status.targetOnline)
		XCTAssertTrue(rig.core.status.targetCanInject)
	}

	func testAckFromTheFutureGivesNoRoundTripSample() {
		var rig = Rig()
		XCTAssertEqual(rig.ack(sent: rig.now + 1).roundTrips, [])
	}

	func testOlderAckDoesNotOverwriteNewerState() {
		var rig = Rig()
		let newest = Ack(session: 7, seq: 10, sentNanos: 0, nextEventID: 0, appliedMotionSeq: 0, controlled: false, canInject: true, displays: targetScreen.frames)
		var older = newest
		older.seq = 9
		older.canInject = false
		rig.send(.ack(newest))
		let out = rig.send(.ack(older))
		XCTAssertEqual(out.roundTrips, [])
		XCTAssertTrue(rig.core.status.targetCanInject)
	}

	func testOnlineStatusExpires() {
		var rig = Rig()
		rig.ack()
		rig.send(.tick, after: 2_400 * ms)
		XCTAssertTrue(rig.core.status.targetOnline)
		rig.send(.tick, after: 200 * ms)
		XCTAssertFalse(rig.core.status.targetOnline)
	}

	func testTargetDisplaysComeFromTheAck() {
		var rig = Rig()
		rig.ack(displays: [CGRect(x: -1000, y: 0, width: 1000, height: 500)])
		let f = rig.push().frames.last!
		XCTAssertEqual(f.x, -999, accuracy: 1e-6)
		XCTAssertEqual(f.y, 250, accuracy: 1e-6)
	}

	// MARK: Frame schedule

	func testFirstTickSendsAFrameAndLocalHeartbeatIsOneSecond() {
		var rig = Rig()
		let first = rig.send(.tick)
		XCTAssertEqual(first.frames.count, 1)
		XCTAssertEqual(first.frames[0].isRemote, false)
		XCTAssertNil(first.frames[0].motion)
		XCTAssertEqual(first.nextTick, rig.now + second)
		XCTAssertEqual(rig.send(.tick, after: 999 * ms).frames, [], "not due yet, and extra ticks are harmless")
		XCTAssertEqual(rig.send(.tick, after: ms).frames.count, 1)
	}

	func testCrossingFrameIsRetriedQuicklyUntilTheTargetConfirmsControl() {
		var rig = Rig()
		rig.cross()
		let sent = rig.now
		XCTAssertEqual(rig.send(.tick).nextTick, sent + Tuning.retryNanos)
		let tick = rig.send(.tick, after: 5 * ms)
		XCTAssertEqual(tick.frames.count, 1)
		XCTAssertTrue(tick.frames[0].isRemote)
	}

	func testRemoteIdleHeartbeatIsOneHundredMillisecondsOnceEverythingIsConfirmed() {
		var rig = Rig()
		rig.cross()
		let sent = rig.now
		XCTAssertEqual(rig.ack(controlled: true).nextTick, sent + Tuning.remoteHeartbeatNanos)
		XCTAssertEqual(rig.send(.tick, after: 99 * ms).frames, [])
		XCTAssertEqual(rig.send(.tick, after: ms).frames.count, 1)
	}

	func testUnconfirmedEventIsRetriedEveryFiveMillisecondsWhileTheLinkAnswers() {
		var rig = Rig()
		rig.cross()
		rig.ack(controlled: true)
		let out = rig.key(.keyDown(code: 1, isRepeat: false), id: 1, after: 20 * ms)
		XCTAssertEqual(out.nextTick, rig.now + 5 * ms)
		let retry = rig.send(.tick, after: 5 * ms)
		XCTAssertEqual(retry.frames.last?.events.count, 1)
	}

	func testDeadLinkIsNotFloodedWithRetries() {
		var rig = Rig()
		rig.cross()
		rig.ack(controlled: true)
		let ackedAt = rig.now
		rig.send(.tick, after: 200 * ms)
		let out = rig.key(.keyDown(code: 1, isRepeat: false), id: 1, after: 250 * ms)
		XCTAssertEqual(out.nextTick, rig.now + Tuning.remoteHeartbeatNanos, "450 ms of silence is past the fast retry window")
		XCTAssertLessThan(out.nextTick, ackedAt + Tuning.targetSilentReturnNanos)
	}

	func testNextTickNeverPassesTheSilenceDeadline() {
		var rig = Rig()
		rig.cross()
		rig.ack(controlled: true)
		let ackedAt = rig.now
		for _ in 0..<9 { rig.send(.tick, after: 100 * ms) }
		let out = rig.motion(0.1, 0, after: 50 * ms)
		XCTAssertEqual(out.nextTick, ackedAt + Tuning.targetSilentReturnNanos + 1)
		XCTAssertTrue(rig.isRemote)
		XCTAssertEqual(rig.send(.tick, after: 50 * ms + 1).endCaptures.count, 1, "the tick it asked for finds the link dead")
	}

	func testProbingSendsAFrameEveryEightMillisecondsUntilTurnedOff() {
		var rig = Rig()
		rig.send(.tick)
		XCTAssertEqual(rig.send(.probing(true)).nextTick, rig.now + Tuning.probeNanos)
		XCTAssertEqual(rig.send(.tick, after: 7 * ms).frames, [])
		XCTAssertEqual(rig.send(.tick, after: ms).frames.count, 1)
		XCTAssertEqual(rig.send(.probing(false)).nextTick, rig.now + Tuning.localHeartbeatNanos)
	}

	func testReturnFrameIsRetriedUntilTheTargetReportsItIsNoLongerControlled() {
		var rig = Rig()
		rig.cross()
		rig.ack(controlled: true)
		let out = rig.send(.fault(.disabled), after: 20 * ms)
		XCTAssertEqual(out.nextTick, rig.now + Tuning.retryNanos)
		XCTAssertEqual(rig.send(.tick, after: 5 * ms).frames.last?.isRemote, false)
		let sent = rig.now
		XCTAssertEqual(rig.ack(controlled: false).nextTick, sent + Tuning.localHeartbeatNanos)
	}
}
