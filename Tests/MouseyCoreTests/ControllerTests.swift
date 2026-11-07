import CoreGraphics
import XCTest
import MouseyCore

final class CrossingTests: XCTestCase {
	func testPushThroughTheEdgeEntersTheOppositeEdgeOfTheTargetAtTheSameFraction() {
		let expected: [Edge: CGPoint] = [
			.right: CGPoint(x: 1, y: 720), .left: CGPoint(x: 2559, y: 720),
			.top: CGPoint(x: 1280, y: 1439), .bottom: CGPoint(x: 1280, y: 1),
		]
		for edge in Edge.allCases {
			var rig = Rig(edge: edge)
			rig.ack()
			let out = rig.push()
			XCTAssertTrue(rig.isRemote, "\(edge)")
			XCTAssertEqual(out.beginCaptures, [CGPoint(x: 720, y: 450)], "\(edge) parks at the center")
			let frame = out.frames.last
			XCTAssertEqual(frame?.isRemote, true)
			XCTAssertEqual(frame?.x ?? .nan, expected[edge]!.x, accuracy: 1e-3, "\(edge)")
			XCTAssertEqual(frame?.y ?? .nan, expected[edge]!.y, accuracy: 1e-3, "\(edge)")
		}
	}

	/// A real MacBook: 1920x1080 above 1680x1050 at an offset, with the target to the left. Both left edges are outer.
	func testBothLeftEdgesOfTheMacBookLayoutCrossOntoTheMinisRightEdge() {
		let macBook = Displays([CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 116, y: 1080, width: 1680, height: 1050)])
		let pushes: [(from: CGPoint, park: CGPoint, lands: CGPoint, warpBack: CGPoint)] = [
			(CGPoint(x: 0.5, y: 540), CGPoint(x: 960, y: 540), CGPoint(x: 2559, y: 720), CGPoint(x: 2, y: 540)),
			(CGPoint(x: 116.5, y: 1080 + 262.5), CGPoint(x: 956, y: 1605), CGPoint(x: 2559, y: 360), CGPoint(x: 118, y: 1342.5)),
		]
		for push in pushes {
			var rig = Rig(edge: .left, local: macBook)
			rig.ack()
			let out = rig.sustain(.watchMotion(location: push.from, dx: -12, dy: 0, buttonsHeld: false))
			XCTAssertTrue(rig.isRemote, "crossing from \(push.from)")
			XCTAssertEqual(out.beginCaptures, [push.park], "parks at the center of the departing display")
			XCTAssertEqual(out.frames.last?.x ?? .nan, push.lands.x, accuracy: 1e-3)
			XCTAssertEqual(out.frames.last?.y ?? .nan, push.lands.y, accuracy: 1e-3, "proportional along the mini's right edge")
			XCTAssertEqual(rig.send(.fault(.disabled)).endCaptures, [push.warpBack], "returns inside the departure edge")
		}
	}

	func testCrossingKeepsTheFractionAlongAnEdgeOfADifferentLength() {
		var rig = Rig()
		rig.ack()
		let out = rig.sustain(.watchMotion(location: CGPoint(x: 1439.5, y: 225), dx: 12, dy: 0, buttonsHeld: false))
		XCTAssertEqual(out.frames.last?.y ?? .nan, 360, accuracy: 1e-3, "a quarter of 900 is a quarter of 1440")
	}

	func testReturnWarpsToTheDepartureEdgeInsideIt() {
		var rig = Rig()
		rig.cross()
		let out = rig.send(.fault(.disabled))
		XCTAssertEqual(out.endCaptures, [CGPoint(x: 1438, y: 450)])
	}

	func testNoCrossingBeforeAnyAck() {
		var rig = Rig()
		rig.push(points: 40, steps: 4)
		XCTAssertFalse(rig.isRemote)
	}

	func testNoCrossingWithAButtonHeld() {
		var rig = Rig()
		rig.ack()
		rig.push(points: 40, steps: 4, buttonsHeld: true)
		XCTAssertFalse(rig.isRemote)
		rig.push()
		XCTAssertTrue(rig.isRemote, "releasing the button allows the next push")
	}

	func testNoCrossingWhenTheLastAckIsOlderThanTheOnlineWindow() {
		var rig = Rig()
		rig.ack()
		rig.send(.tick, after: 2_501 * ms)
		rig.push(points: 40, steps: 4)
		XCTAssertFalse(rig.isRemote)
		XCTAssertFalse(rig.core.status.targetOnline)
	}

	func testCrossingWithinTheOnlineWindowWorks() {
		var rig = Rig()
		rig.ack()
		rig.send(.tick, after: 2_300 * ms)
		rig.push()
		XCTAssertTrue(rig.isRemote)
	}

	func testNoCrossingWhenTheTargetCannotInject() {
		var rig = Rig()
		rig.ack(canInject: false)
		rig.push(points: 40, steps: 4)
		XCTAssertFalse(rig.isRemote)
		XCTAssertFalse(rig.core.status.targetCanInject)
		rig.ack(canInject: true)
		rig.push()
		XCTAssertTrue(rig.isRemote)
	}

	func testPushDoesNotBuildUpWhileCrossingIsRefused() {
		var rig = Rig()
		rig.push(points: 40, steps: 4)
		rig.ack()
		rig.send(rig.watch(1), after: 4 * ms)
		XCTAssertFalse(rig.isRemote, "forty refused points are not banked")
	}

	func testInnerEdgeBesideASecondDisplayIsNotACrossing() {
		let two = Displays([CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)])
		var rig = Rig(local: two)
		rig.ack()
		for _ in 0..<5 { rig.send(.watchMotion(location: CGPoint(x: 1439.5, y: 450), dx: 20, dy: 0, buttonsHeld: false), after: 4 * ms) }
		XCTAssertFalse(rig.isRemote)
		rig.sustain(.watchMotion(location: CGPoint(x: 3359.5, y: 450), dx: 6, dy: 0, buttonsHeld: false))
		XCTAssertTrue(rig.isRemote, "the outer edge of the second display crosses")
	}

	func testDepartureFromASecondDisplayParksAtItsCenter() {
		let two = Displays([CGRect(x: -1440, y: 0, width: 1440, height: 900), CGRect(x: 0, y: -100, width: 1920, height: 1080)])
		var rig = Rig(edge: .right, local: two)
		rig.ack()
		var out = rig.sustain(.watchMotion(location: CGPoint(x: 1919.5, y: 440), dx: 12, dy: 0, buttonsHeld: false))
		XCTAssertEqual(out.beginCaptures, [CGPoint(x: 960, y: 440)])
		out = rig.send(.fault(.disabled))
		XCTAssertEqual(out.endCaptures, [CGPoint(x: 1918, y: 440)], "540 of 1080 down is the middle, so y 440 returns to y 440")
	}

	func testReturnUsesTheDisplayNearestTheOldCenterIfTheDepartureDisplayIsGone() {
		let two = Displays([CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)])
		var rig = Rig(edge: .right, local: two)
		rig.ack()
		rig.sustain(.watchMotion(location: CGPoint(x: 3359.5, y: 540), dx: 12, dy: 0, buttonsHeld: false))
		XCTAssertTrue(rig.isRemote)
		rig.send(.localDisplays(laptop))
		let out = rig.send(.fault(.disabled))
		XCTAssertEqual(out.endCaptures, [CGPoint(x: 1438, y: 450)])
	}

	func testNoCrossingAfterAReturnUntilTheTargetAnswersAgain() {
		var rig = Rig()
		rig.cross()
		for _ in 0..<12 { rig.send(.tick, after: 100 * ms) }
		XCTAssertEqual(rig.core.status.lastReturn, .targetSilent)
		rig.push()
		XCTAssertFalse(rig.isRemote, "inside the online window, but nothing has answered since the return")
		rig.ack(after: ms)
		rig.push()
		XCTAssertTrue(rig.isRemote)
	}

	func testPauseResetsThePush() {
		var rig = Rig()
		rig.ack()
		rig.send(rig.watch(6), after: 4 * ms)
		rig.send(rig.watch(6), after: 300 * ms)
		XCTAssertFalse(rig.isRemote)
		rig.send(rig.watch(6), after: 40 * ms)
		XCTAssertFalse(rig.isRemote, "12 points, but the pause restarted the minimum time")
		rig.send(rig.watch(1), after: 40 * ms)
		XCTAssertTrue(rig.isRemote)
	}

	func testSlowPushCrosses() {
		var rig = Rig()
		rig.ack()
		for _ in 0..<12 where !rig.isRemote { rig.send(rig.watch(1), after: 200 * ms); rig.ack() }
		XCTAssertTrue(rig.isRemote)
	}

	func testLeavingTheEdgeResetsThePushButIdlingOnItDoesNot() {
		var rig = Rig()
		rig.ack()
		rig.send(rig.watch(6), after: 4 * ms)
		rig.send(.watchMotion(location: CGPoint(x: 700, y: 450), dx: 6, dy: 0, buttonsHeld: false), after: 4 * ms)
		rig.send(rig.watch(6), after: 4 * ms)
		XCTAssertFalse(rig.isRemote)
		rig.send(rig.watch(0), after: 4 * ms)
		rig.send(rig.watch(-3), after: 4 * ms)
		rig.send(rig.watch(6), after: 90 * ms)
		XCTAssertTrue(rig.isRemote, "motion that is not outward neither adds nor erases")
	}

	func testLocalInputWhileRemoteIsIgnoredAndRemoteInputWhileLocalPasses() {
		var rig = Rig()
		rig.ack()
		var out = rig.send(.grabbedMotion(dx: 5, dy: 5, bytes: payload(.other)))
		XCTAssertEqual(out.disposition, .pass)
		XCTAssertEqual(out.effects, [])
		out = rig.key(.keyDown(code: 1, isRepeat: false))
		XCTAssertEqual([out.disposition], [.pass])
		XCTAssertEqual(out.effects, [])
		rig.push()
		out = rig.send(rig.watch(50))
		XCTAssertEqual(out.effects, [], "watch events are ignored while remote")
	}
}

final class RemoteInputTests: XCTestCase {
	private func remoteRig() -> Rig {
		var rig = Rig()
		rig.cross()
		return rig
	}

	func testMotionIsConsumedMovesThePositionAndSendsAFrameWithTheBytes() {
		var rig = remoteRig()
		let out = rig.motion(30, -10, after: 8 * ms, id: 5)
		XCTAssertEqual(out.disposition, .consume)
		let f = out.frames.last!
		XCTAssertEqual([f.x, f.y], [31, 710])
		XCTAssertEqual(f.motion, payload(.other, id: 5))
		XCTAssertEqual(f.motionSeq, 1)
		XCTAssertTrue(f.isRemote)
	}

	func testMotionIsNumberedAndOnlyTheLatestBytesTravel() {
		var rig = remoteRig()
		rig.motion(1, 0, id: 1)
		let f = rig.motion(1, 0, id: 2).frames.last!
		XCTAssertEqual(f.motionSeq, 2)
		XCTAssertEqual(f.motion, payload(.other, id: 2))
	}

	func testCrossingEventFedBackWithNoDeltaCountsAsMotion() {
		var rig = remoteRig()
		let f = rig.motion(0, 0, id: 9).frames.last!
		XCTAssertEqual([f.x, f.y, Double(f.motionSeq)], [1, 720, 1])
		XCTAssertEqual(f.motion, payload(.other, id: 9))
	}

	func testMotionIsClampedAtTheFarEdges() {
		var rig = remoteRig()
		let f = rig.motion(10_000, 10_000).frames.last!
		XCTAssertEqual(f.x, 2560, accuracy: 1e-6)
		XCTAssertEqual(f.y, 1440, accuracy: 1e-6)
		XCTAssertTrue(rig.isRemote)
	}

	func testPushingBackThroughTheEntryEdgeReturnsAtTheExitFraction() {
		var rig = remoteRig()
		rig.motion(0, 200)
		rig.motion(-30, 0, after: 4 * ms)
		let out = rig.motion(-30, 0, after: 90 * ms)
		XCTAssertEqual(out.endCaptures.first?.x ?? .nan, 1438, accuracy: 1e-6)
		XCTAssertEqual(out.endCaptures.first?.y ?? .nan, 900 * 920.0 / 1440, accuracy: 1e-3)
		XCTAssertEqual(rig.core.status.lastReturn, .targetEdge)
		XCTAssertEqual(out.frames.last?.isRemote, false)
	}

	func testSmallOvershootsAddUpToAnExit() {
		var rig = remoteRig()
		rig.motion(-1, 0)
		var returned = false
		for _ in 0..<4 where !returned { returned = !rig.motion(-3, 0, after: 30 * ms).endCaptures.isEmpty }
		XCTAssertTrue(returned)
	}

	func testMovingAwayFromTheEntryEdgeResetsTheExitPush() {
		var rig = remoteRig()
		rig.motion(-6, 0, after: 4 * ms)
		rig.motion(200, 0, after: 4 * ms)
		rig.motion(-199, 0, after: 4 * ms)
		XCTAssertFalse(rig.motion(-6, 0, after: 4 * ms).endCaptures.count > 0)
		XCTAssertTrue(rig.isRemote)
	}

	func testNoExitWhileAButtonIsHeldOnTheTarget() {
		var rig = remoteRig()
		let down = rig.key(.button(index: 0, isDown: true))
		XCTAssertEqual(down.disposition, .consume)
		XCTAssertTrue(rig.motion(-100, 0, after: 4 * ms).endCaptures.isEmpty)
		XCTAssertTrue(rig.motion(-100, 0, after: 4 * ms).endCaptures.isEmpty)
		rig.key(.button(index: 0, isDown: false))
		rig.motion(-100, 0, after: 4 * ms)
		XCTAssertFalse(rig.motion(-100, 0, after: 90 * ms).endCaptures.isEmpty, "with the button up, a sustained push leaves")
	}

	func testTheEdgeFacingTheMacBookIsNotAnExitIfAnotherDisplayLiesBeyondIt() {
		var rig = Rig()
		let twoTargets = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
		rig.ack(displays: twoTargets)
		rig.push()
		XCTAssertTrue(rig.isRemote)
		rig.motion(1500, 0)
		let out = rig.motion(-1000, 0, after: 4 * ms)
		XCTAssertTrue(rig.isRemote, "the pointer crossed to the second target display and is not at an outer edge")
		XCTAssertEqual(out.frames.last?.x ?? .nan, 501, accuracy: 1e-6)
		rig.motion(-1000, 0, after: 4 * ms)
		XCTAssertTrue(rig.motion(-1000, 0, after: 90 * ms).endCaptures.isEmpty == false, "then leaves through the outer edge")
	}

	func testEntryUsesTheOutermostTargetDisplay() {
		var rig = Rig(edge: .right)
		rig.ack(displays: [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: -1500, y: 0, width: 1500, height: 1000)])
		let out = rig.push()
		XCTAssertEqual(out.frames.last?.x ?? .nan, -1499, accuracy: 1e-6)
		XCTAssertEqual(out.frames.last?.y ?? .nan, 500, accuracy: 1e-6)
	}

	// MARK: Key routing through the core

	func testKeyDownIsForwardedWithThePositionAndMotionCounterAtCapture() {
		var rig = remoteRig()
		rig.motion(10, 5, id: 1)
		let out = rig.key(.keyDown(code: 1, isRepeat: false), id: 42)
		XCTAssertEqual(out.disposition, .consume)
		let e = out.frames.last!.events
		XCTAssertEqual(e.count, 1)
		XCTAssertEqual([e[0].x, e[0].y, Double(e[0].motionSeq)], [11, 725, 2 - 1])
		XCTAssertEqual(e[0].bytes, payload(.keyDown, id: 42))
	}

	func testEventsStayInEveryFrameUntilAcked() {
		var rig = remoteRig()
		rig.key(.keyDown(code: 1, isRepeat: false), id: 1)
		rig.key(.keyUp(code: 1), id: 2)
		var f = rig.send(.tick, after: 10 * ms).frames.last!
		XCTAssertEqual(f.events.map { payloadID($0.bytes) }, [1, 2])
		XCTAssertEqual(f.firstEventID, 0)
		rig.ack(next: 1, controlled: true)
		f = rig.send(.tick, after: 10 * ms).frames.last!
		XCTAssertEqual(f.events.map { payloadID($0.bytes) }, [2])
		XCTAssertEqual(f.firstEventID, 1)
	}

	func testRepeatIsSentOnceInTheNextFrameAndNeverAgain() {
		var rig = remoteRig()
		rig.key(.keyDown(code: 1, isRepeat: false), id: 1)
		let out = rig.key(.keyDown(code: 1, isRepeat: true), id: 2)
		XCTAssertEqual(out.disposition, .consume)
		XCTAssertEqual(out.frames.last?.repeats, [payload(.keyDown, id: 2)])
		XCTAssertEqual(out.frames.last?.events.count, 1, "a repeat is not an event")
		XCTAssertEqual(rig.send(.tick, after: 10 * ms).frames.last?.repeats, [])
	}

	func testKeyHeldBeforeCrossingPassesToTheLocalMac() {
		var rig = remoteRig()
		for event in [EventClass.keyDown(code: 1, isRepeat: true), .keyUp(code: 1), .modifier(code: 55, isDown: false)] {
			let out = rig.key(event)
			XCTAssertEqual(out.disposition, .pass)
			XCTAssertEqual(out.effects, [])
		}
	}

	func testKeyPressedWhileRemoteReleasesOnTheTarget() {
		var rig = remoteRig()
		rig.key(.keyDown(code: 1, isRepeat: false))
		let out = rig.key(.keyUp(code: 1), id: 3)
		XCTAssertEqual(out.disposition, .consume)
		XCTAssertEqual(out.frames.last?.events.count, 2)
	}

	func testRouterStateDoesNotSurviveAReturn() {
		var rig = remoteRig()
		rig.key(.keyDown(code: 1, isRepeat: false))
		rig.send(.fault(.disabled))
		rig.ack(after: ms)
		rig.push()
		XCTAssertTrue(rig.isRemote)
		XCTAssertEqual(rig.key(.keyUp(code: 1)).disposition, .pass, "the new crossing never saw this key go down")
	}

	func testPanicChordReturnsAndIsConsumed() {
		var rig = remoteRig()
		let out = rig.key(.keyDown(code: 53, isRepeat: false), flags: 0x40000 | 0x80000 | 0x100000 | 0x100)
		XCTAssertEqual(out.disposition, .consume)
		XCTAssertEqual(out.endCaptures.count, 1)
		XCTAssertEqual(rig.core.status.lastReturn, .panicChord)
	}

	func testEscapeAloneOrWithPartOfTheChordIsForwarded() {
		var rig = remoteRig()
		for flags: UInt64 in [0, 0x40000, 0x40000 | 0x80000, 0x100000 | 0x80000] {
			let out = rig.key(.keyDown(code: 53, isRepeat: false), flags: flags)
			XCTAssertEqual(out.disposition, .consume)
			XCTAssertEqual(out.endCaptures, [])
		}
		XCTAssertTrue(rig.isRemote)
		XCTAssertEqual(rig.key(.keyDown(code: 12, isRepeat: false), flags: 0x40000 | 0x80000 | 0x100000).endCaptures, [], "the chord needs Esc")
	}

	// MARK: Frames

	func testReturnFrameIsLocalEmptyAndSkipsTheAbandonedEventIDs() {
		var rig = remoteRig()
		rig.motion(5, 5, id: 1)
		for i in 0..<3 { rig.key(.button(index: i, isDown: true), id: UInt32(10 + i)) }
		let f = rig.send(.fault(.disabled)).frames.last!
		XCTAssertFalse(f.isRemote)
		XCTAssertNil(f.motion)
		XCTAssertEqual(f.events, [])
		XCTAssertEqual(f.firstEventID, 3)
		let later = rig.send(.tick, after: 2 * second).frames.last!
		XCTAssertEqual([later.events.count, later.repeats.count], [0, 0])
		XCTAssertNil(later.motion)
		XCTAssertEqual(later.firstEventID, 3, "the abandoned events never come back")
	}

	func testOldMotionDoesNotLeakIntoTheNextCrossing() {
		var rig = remoteRig()
		rig.motion(5, 5, id: 1)
		rig.send(.fault(.disabled))
		rig.ack(after: ms)
		let f = rig.push().frames.last!
		XCTAssertNil(f.motion)
		XCTAssertEqual(f.motionSeq, 1)
	}

	func testFrameSeqIncreasesAndCarriesTheClock() {
		var rig = remoteRig()
		let a = rig.motion(1, 0, after: 3 * ms).frames.last!, b = rig.motion(1, 0, after: 3 * ms).frames.last!
		XCTAssertEqual(b.seq, a.seq + 1)
		XCTAssertEqual(b.sentNanos, rig.now)
		XCTAssertEqual(b.session, 7)
	}

	func testConfirmedMotionIsNotResent() {
		var rig = remoteRig()
		rig.motion(1, 0, id: 4)
		rig.ack(motion: 1, controlled: true)
		let f = rig.send(.tick, after: 100 * ms).frames.last!
		XCTAssertNil(f.motion)
		XCTAssertEqual(f.motionSeq, 1)
	}

	func testUnconfirmedMotionIsResentEvenWhenAnEventIsStampedPastIt() {
		var rig = remoteRig()
		rig.motion(1, 0, id: 4)
		rig.motion(1, 0, id: 5)
		rig.ack(motion: 1, controlled: true)
		XCTAssertEqual(rig.send(.tick, after: 5 * ms).frames.last?.motion, payload(.other, id: 5))
	}

	func testFramesStayInsideTheDatagramLimitAndMotionWaitsForTheEvents() {
		var rig = remoteRig()
		rig.motion(1, 0, id: 1000)
		// Random bytes, because compression would fit anything repetitive in one frame.
		var rng = RNG(seed: 42)
		let noise = (0..<8).map { _ in Data((0..<230).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
		let bigEvent = { (i: UInt32) in payload(.buttonDown, id: i) + noise[Int(i)] }
		var frames: [Frame] = []
		for i in 0..<8 {
			rig.now += ms
			frames += rig.send(.grabbed(.button(index: i, isDown: true), bytes: bigEvent(UInt32(i)), flags: 0)).frames
		}
		let last = frames.last!
		XCTAssertLessThanOrEqual(Wire.encode(last).count, Wire.maxDatagram)
		XCTAssertEqual(last.events.map { payloadID($0.bytes) }, Array(0..<UInt32(last.events.count)), "oldest first and contiguous")
		XCTAssertLessThan(last.events.count, 8, "the budget cut the run")
		XCTAssertNil(last.motion, "a motion newer than the withheld events must wait for them")
		XCTAssertFalse(frames.contains { Wire.encode($0).count > Wire.maxDatagram })
		rig.ack(next: UInt32(last.events.count), motion: 0, controlled: true)
		let rest = rig.send(.tick, after: 5 * ms).frames.last!
		XCTAssertEqual(rest.firstEventID, UInt32(last.events.count))
	}

	func testMotionRidesAlongWhenEverythingFits() {
		var rig = remoteRig()
		rig.key(.keyDown(code: 1, isRepeat: false), id: 1)
		let f = rig.motion(1, 0, id: 2).frames.last!
		XCTAssertEqual(f.motion, payload(.other, id: 2))
		XCTAssertEqual(f.events.count, 1)
	}

	func testALoneOversizeEventStillGoes() {
		var rig = remoteRig()
		let out = rig.send(.grabbed(.button(index: 0, isDown: true), bytes: Data(repeating: 7, count: 2000), flags: 0))
		XCTAssertEqual(out.frames.last?.events.count, 1)
	}

	func testRepeatsAreSentOncePerFrameInsideTheLimit() {
		var rig = remoteRig()
		rig.key(.keyDown(code: 1, isRepeat: false), id: 1)
		let outs = (0..<3).map { _ in rig.send(.grabbed(.keyDown(code: 1, isRepeat: true), bytes: Data(repeating: 1, count: 400), flags: 0)) }
		for out in outs { XCTAssertLessThanOrEqual(Wire.encode(out.frames.last!).count, Wire.maxDatagram) }
		XCTAssertEqual(outs.map { $0.frames.last!.repeats.count }, [1, 1, 1])
	}
}
