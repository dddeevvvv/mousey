import CoreGraphics
import XCTest
import MouseyCore

struct TargetRig {
	var core = TargetCore(displays: targetScreen, classify: classify)
	var now: Tick = 5 * second
	var seq: UInt32 = 0
	var nextID: UInt32 = 0

	mutating func event(_ kind: Kind, _ a: UInt8 = 0, _ b: UInt8 = 0, at p: CGPoint = CGPoint(x: 100, y: 100), stamp: UInt32 = 0) -> WireEvent {
		nextID += 1
		return WireEvent(x: p.x, y: p.y, motionSeq: stamp, bytes: payload(kind, a, b, id: nextID))
	}

	mutating func frame(
		_ events: [WireEvent] = [], first: UInt32? = nil, remote: Bool = true, session: UInt32 = 1, seq explicitSeq: UInt32? = nil,
		motion: Data? = nil, motionSeq: UInt32 = 0, at p: CGPoint = CGPoint(x: 100, y: 100), repeats: [Data] = []
	) -> Frame {
		if let explicitSeq { seq = explicitSeq } else { seq &+= 1 }
		return Frame(session: session, seq: seq, sentNanos: 77, isRemote: remote, x: p.x, y: p.y, motionSeq: motionSeq, motion: motion,
			firstEventID: first ?? (events.isEmpty ? 0 : UInt32(truncatingIfNeeded: nextID) - UInt32(events.count)), events: events, repeats: repeats)
	}

	@discardableResult
	mutating func receive(_ f: Frame, canInject: Bool = true, after nanos: Tick = 0) -> (commands: [TargetCommand], ack: Ack) {
		now += nanos
		return core.receive(f, canInject: canInject, now: now)
	}
}

func posts(_ c: [TargetCommand]) -> [UInt32] {
	c.compactMap {
		switch $0 {
		case .post(let b, _), .postMotion(let b, _): return payloadID(b)
		default: return nil
		}
	}
}

final class TargetTests: XCTestCase {
	func testDeliversEachEventOnceAndAcksIt() {
		var t = TargetRig()
		let e = [t.event(.keyDown, 4), t.event(.keyUp, 4)]
		let first = t.receive(t.frame(e, first: 0))
		XCTAssertEqual(first.commands.filter { $0 != .declareUserActivity }.count, 2)
		XCTAssertEqual(first.ack.nextEventID, 2)
		let again = t.receive(t.frame(e, first: 0))
		XCTAssertEqual(again.commands, [])
		XCTAssertEqual(again.ack.nextEventID, 2)
		XCTAssertTrue(first.ack.controlled)
	}

	func testStaleOrDuplicateFramesAckAndChangeNothing() {
		var t = TargetRig()
		t.receive(t.frame(seq: 10))
		let e = t.event(.keyDown, 4)
		let dup = t.receive(t.frame([e], first: 0, seq: 10))
		XCTAssertEqual(dup.commands, [])
		XCTAssertEqual(dup.ack.seq, 10)
		XCTAssertEqual(dup.ack.nextEventID, 0)
		let old = t.receive(t.frame([e], first: 0, seq: 9))
		XCTAssertEqual(old.commands, [])
		XCTAssertEqual(old.ack.nextEventID, 0, "the event in the stale frame was not applied")
		XCTAssertEqual(t.receive(t.frame([e], first: 0, seq: 11)).ack.nextEventID, 1)
	}

	func testSequenceNumbersMayWrap() {
		var t = TargetRig()
		t.receive(t.frame(seq: UInt32.max - 1))
		t.receive(t.frame(seq: UInt32.max))
		let e = t.event(.keyDown, 4)
		XCTAssertEqual(t.receive(t.frame([e], first: 0, seq: 0)).ack.nextEventID, 1, "0 follows UInt32.max")
		XCTAssertEqual(t.receive(t.frame([e], first: 0, seq: UInt32.max)).commands, [], "UInt32.max is now old")
	}

	func testMotionCounterMayWrap() {
		var t = TargetRig()
		let m = payload(.other, id: 1)
		for step in [UInt32(0x7FFF_FFFF), 0xFFFF_FFFE, 1] {
			XCTAssertEqual(posts(t.receive(t.frame(motion: m, motionSeq: step)).commands), [1], "\(step) is newer than its predecessor")
		}
		XCTAssertEqual(posts(t.receive(t.frame(motion: m, motionSeq: 0xFFFF_FFFE)).commands), [], "and the number before the wrap is now old")
	}

	func testNewSessionReleasesHeldInputAndStartsOver() {
		var t = TargetRig()
		t.receive(t.frame([t.event(.keyDown, 4), t.event(.buttonDown, 0)], first: 100, session: 1, seq: 50))
		let r = t.receive(t.frame([t.event(.keyDown, 9)], first: 7, session: 2, seq: 1))
		XCTAssertEqual(Array(r.commands.prefix(2)), [.releaseButton(index: 0, at: CGPoint(x: 100, y: 100)), .releaseKey(code: 4)])
		XCTAssertEqual(r.ack.nextEventID, 8, "the inbox restarted at the new first ID and delivered one event")
		XCTAssertEqual(r.ack.appliedMotionSeq, 0)
	}

	func testFirstFrameOfASessionIsAcceptedWhateverItsSeq() {
		var t = TargetRig()
		XCTAssertEqual(t.receive(t.frame([t.event(.keyDown, 1)], first: 0, seq: 0)).ack.nextEventID, 1)
	}

	func testRemoteFalseReleasesEverythingInOrderAtTheLastPostedPosition() {
		var t = TargetRig()
		let at = CGPoint(x: 321, y: 123)
		let scroll = t.event(.scroll, 1, 0), pinch = t.event(.gesture, 2, 8, at: at), swipe = t.event(.gesture, 1, 23, at: at)
		let held = [
			t.event(.modifierDown, 55), t.event(.keyDown, 12), t.event(.buttonDown, 1), t.event(.buttonDown, 0),
			scroll, swipe, pinch,
		]
		t.receive(t.frame(held, first: 0))
		let r = t.receive(t.frame(remote: false))
		XCTAssertEqual(r.commands, [
			.endGesture(bytes: pinch.bytes, at: at), .endGesture(bytes: swipe.bytes, at: at), .endScroll(bytes: scroll.bytes, at: at),
			.releaseButton(index: 0, at: at), .releaseButton(index: 1, at: at), .releaseKey(code: 12), .releaseModifier(code: 55),
		])
		XCTAssertFalse(r.ack.controlled)
		XCTAssertEqual(t.receive(t.frame(remote: false)).commands, [], "releasing twice does nothing")
	}

	func testReleasedKeysAreNotHeldAnyMore() {
		var t = TargetRig()
		t.receive(t.frame([t.event(.keyDown, 12), t.event(.keyUp, 12), t.event(.buttonDown, 0), t.event(.buttonUp, 0), t.event(.scroll, 1, 0), t.event(.scroll, 4, 0)], first: 0))
		XCTAssertEqual(t.receive(t.frame(remote: false)).commands, [])
	}

	func testScrollMomentumStaysOpenUntilItEnds() {
		var t = TargetRig()
		let momentum = t.event(.scroll, 0, 1)
		t.receive(t.frame([t.event(.scroll, 1, 0), t.event(.scroll, 4, 0), momentum], first: 0))
		XCTAssertEqual(t.receive(t.frame(remote: false)).commands, [.endScroll(bytes: momentum.bytes, at: CGPoint(x: 100, y: 100))])
	}

	func testSilenceReleasesAndALaterRemoteFrameResumes() {
		var t = TargetRig()
		t.receive(t.frame([t.event(.keyDown, 12)], first: 0))
		XCTAssertEqual(t.core.tick(now: t.now + 1_199 * ms), [])
		XCTAssertTrue(t.core.status.controlled)
		XCTAssertEqual(t.core.tick(now: t.now + 1_200 * ms), [.releaseKey(code: 12)])
		XCTAssertFalse(t.core.status.controlled)
		XCTAssertEqual(t.core.tick(now: t.now + 2_000 * ms), [])
		XCTAssertTrue(t.receive(t.frame(), after: 3 * second).ack.controlled)
	}

	func testTickBeforeAnyFrameDoesNothing() {
		var t = TargetRig()
		XCTAssertEqual(t.core.tick(now: 100 * second), [])
		XCTAssertFalse(t.core.status.controllerSeen)
	}

	func testRepeatPostsOnlyWhileTheKeyIsHeldAndIsNeverRetried() {
		var t = TargetRig()
		let rep = payload(.keyRepeat, 12, id: 900)
		XCTAssertEqual(posts(t.receive(t.frame(repeats: [rep])).commands), [], "not held yet")
		t.receive(t.frame([t.event(.keyDown, 12)], first: 0))
		let r = t.receive(t.frame(repeats: [rep, rep]))
		XCTAssertEqual(posts(r.commands), [900, 900])
		XCTAssertEqual(posts(t.receive(t.frame([], first: 1)).commands), [], "only frames that carry it post it")
		t.receive(t.frame([t.event(.keyUp, 12)], first: 1))
		XCTAssertEqual(posts(t.receive(t.frame(repeats: [rep])).commands), [], "released")
	}

	func testRepeatForADifferentHeldKeyIsDropped() {
		var t = TargetRig()
		t.receive(t.frame([t.event(.keyDown, 12)], first: 0))
		XCTAssertEqual(posts(t.receive(t.frame(repeats: [payload(.keyRepeat, 13, id: 5)])).commands), [])
	}

	func testUnrebuildablePayloadsAreDroppedCountedAndTheirIDAdvances() {
		var t = TargetRig()
		let bad = t.event(.unrebuildable)
		let r = t.receive(t.frame([bad, t.event(.keyDown, 1)], first: 0, motion: payload(.unrebuildable), motionSeq: 3))
		XCTAssertEqual(posts(r.commands).count, 1)
		XCTAssertEqual(r.ack.nextEventID, 2)
		XCTAssertEqual(t.core.status.droppedEvents, 2)
		XCTAssertEqual(r.ack.appliedMotionSeq, 3, "a bad motion is not resent forever")
	}

	// MARK: Capture order

	func testMotionGoesBeforeAnEventStampedAtOrAboveIt() {
		var t = TargetRig()
		let m = payload(.other, id: 500), p = CGPoint(x: 300, y: 300), q = CGPoint(x: 400, y: 400)
		let e1 = t.event(.keyDown, 1, at: p, stamp: 3), e2 = t.event(.buttonDown, 0, at: q, stamp: 5)
		let r = t.receive(t.frame([e1, e2], first: 0, motion: m, motionSeq: 5, at: q))
		XCTAssertEqual(r.commands.filter { $0 != .declareUserActivity }, [
			.post(bytes: e1.bytes, at: p), .postMotion(bytes: m, at: q), .post(bytes: e2.bytes, at: q),
		])
		XCTAssertEqual(r.ack.appliedMotionSeq, 5)
	}

	func testMotionNewerThanEveryEventGoesLast() {
		var t = TargetRig()
		let m = payload(.other, id: 500), p = CGPoint(x: 300, y: 300), end = CGPoint(x: 900, y: 800)
		let e = t.event(.buttonDown, 0, at: p, stamp: 2)
		let r = t.receive(t.frame([e], first: 0, motion: m, motionSeq: 9, at: end))
		XCTAssertEqual(r.commands.filter { $0 != .declareUserActivity }, [.post(bytes: e.bytes, at: p), .postMotion(bytes: m, at: end)])
	}

	func testAnEventsStampRetiresOlderMotion() {
		var t = TargetRig()
		let e = t.event(.buttonDown, 0, stamp: 4)
		XCTAssertEqual(t.receive(t.frame([e], first: 0)).ack.appliedMotionSeq, 4)
		XCTAssertEqual(posts(t.receive(t.frame(motion: payload(.other, id: 77), motionSeq: 3)).commands), [], "motion 3 is older than what the click already passed")
		XCTAssertEqual(posts(t.receive(t.frame(motion: payload(.other, id: 78), motionSeq: 5)).commands), [78])
	}

	func testMotionAlreadyAppliedIsNotPostedAgain() {
		var t = TargetRig()
		let m = payload(.other, id: 1)
		XCTAssertEqual(posts(t.receive(t.frame(motion: m, motionSeq: 2)).commands), [1])
		XCTAssertEqual(posts(t.receive(t.frame(motion: m, motionSeq: 2)).commands), [])
	}

	func testCoalesceKeepsTheLastMotionOfARunAndEverythingElse() {
		let a = TargetCommand.postMotion(bytes: payload(.other, id: 1), at: .zero)
		let b = TargetCommand.postMotion(bytes: payload(.other, id: 2), at: .zero)
		let click = TargetCommand.post(bytes: payload(.buttonDown, id: 3), at: .zero)
		XCTAssertEqual(coalesce([a, b, click, a, click, b, a]), [b, click, a, click, a])
		XCTAssertEqual(coalesce([]), [])
	}

	// MARK: Other behavior

	func testWithoutPermissionNothingIsPostedAndTheAckSaysSo() {
		var t = TargetRig()
		let r = t.receive(t.frame([t.event(.keyDown, 1)], first: 0, motion: payload(.other), motionSeq: 1), canInject: false)
		XCTAssertEqual(r.commands, [])
		XCTAssertFalse(r.ack.canInject)
		XCTAssertFalse(r.ack.controlled)
		XCTAssertEqual(r.ack.nextEventID, 0, "events are not consumed that were not applied")
	}

	func testUserActivityIsDeclaredAtMostOncePerSecond() {
		var t = TargetRig()
		let times: [Tick] = [0, 400 * ms, 400 * ms, 300 * ms]
		let counts = times.map { dt in t.receive(t.frame(motion: payload(.other, id: UInt32(t.seq)), motionSeq: t.seq + 1), after: dt).commands.filter { $0 == .declareUserActivity }.count }
		XCTAssertEqual(counts, [1, 0, 0, 1], "declared at 0 ms, then again at 1100 ms")
		XCTAssertEqual(t.receive(t.frame(), after: 5 * second).commands, [], "a frame with no input declares nothing")
	}

	func testActivityIsDeclaredBeforeTheInputItAnnounces() {
		var t = TargetRig()
		XCTAssertEqual(t.receive(t.frame([t.event(.keyDown, 1)], first: 0)).commands.first, .declareUserActivity)
	}

	func testAckEchoesTheFrameAndReportsDisplays() {
		var t = TargetRig()
		var f = t.frame()
		f.sentNanos = 123_456
		let a = t.receive(f).ack
		XCTAssertEqual([a.session, a.seq], [f.session, f.seq])
		XCTAssertEqual(a.sentNanos, 123_456)
		XCTAssertEqual(a.displays, targetScreen.frames)
		t.core.setDisplays(Displays((0..<10).map { CGRect(x: $0 * 10, y: 0, width: 10, height: 10) }))
		XCTAssertEqual(t.receive(t.frame()).ack.displays.count, 8)
	}
}
