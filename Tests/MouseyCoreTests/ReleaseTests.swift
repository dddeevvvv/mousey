import MouseyCore
import XCTest

final class ReleaseTests: XCTestCase {
	func testAnnouncesOnlyAHigherNumber() {
		XCTAssertEqual(newerRelease(tag: "v0.3.0", current: "0.2.0"), "0.3.0")
		XCTAssertEqual(newerRelease(tag: "0.3.0", current: "0.2.0"), "0.3.0")
		XCTAssertEqual(newerRelease(tag: "0.10.0", current: "0.9.0"), "0.10.0", "numbers compare as numbers, not text")
		XCTAssertEqual(newerRelease(tag: "1.0.1", current: "1.0"), "1.0.1")
		XCTAssertNil(newerRelease(tag: "0.2.0", current: "0.2.0"))
		XCTAssertNil(newerRelease(tag: "0.1.9", current: "0.2.0"))
		XCTAssertNil(newerRelease(tag: "1.0", current: "1.0.0"), "1.0 and 1.0.0 are the same release")
		XCTAssertNil(newerRelease(tag: "1.0.0", current: "1.0"), "1.0 and 1.0.0 are the same release")
	}

	func testATagThatIsNotAPlainNumberAnnouncesNothing() {
		let hostile = ["", "v", ".", "1.", ".1", "1..2", "1.2.3.4.5", "v9.9.9-beta", "9.9.9 click here", "9.9.9\n", " 9.9.9", "../9", "1234567.0", "٩.٩", "v9.9.9.", "vv9", "-1.0", "+9"]
		for tag in hostile {
			XCTAssertNil(newerRelease(tag: tag, current: "0.2.0"), "tag \(tag.debugDescription)")
		}
	}

	func testARunningVersionThatIsNotANumberAnnouncesNothing() {
		XCTAssertNil(newerRelease(tag: "9.9.9", current: "dev"))
	}

	func testChecksAtMostOnceADay() {
		let start = Date(timeIntervalSince1970: 1_000_000)
		var state = UpdateState(enabled: true, lastCheck: nil, latestTag: nil)
		XCTAssertTrue(state.claimDailyCheck(now: start), "the first check is due")
		XCTAssertFalse(state.claimDailyCheck(now: start.addingTimeInterval(23 * 3600)))
		XCTAssertEqual(state.lastCheck, start, "a refused check does not push the next one back")
		XCTAssertTrue(state.claimDailyCheck(now: start.addingTimeInterval(24 * 3600)))
	}

	func testAClockSetBackwardsCannotSilenceTheCheck() {
		let start = Date(timeIntervalSince1970: 1_000_000)
		var state = UpdateState(enabled: true, lastCheck: start, latestTag: nil)
		XCTAssertTrue(state.claimDailyCheck(now: start.addingTimeInterval(-400 * 24 * 3600)))
	}

	func testTurnedOffMeansNoRequestAndNoNotice() {
		let start = Date(timeIntervalSince1970: 1_000_000)
		var state = UpdateState(enabled: false, lastCheck: nil, latestTag: "9.9.9")
		XCTAssertFalse(state.claimDailyCheck(now: start))
		XCTAssertNil(state.lastCheck, "turning it back on checks straight away")
		XCTAssertNil(state.notice(current: "0.2.0"))
		state.enabled = true
		XCTAssertEqual(state.notice(current: "0.2.0"), "9.9.9")
		XCTAssertTrue(state.claimDailyCheck(now: start))
	}

	func testATagThatIsNotAPlainNumberIsNotKept() {
		var state = UpdateState(enabled: true, lastCheck: nil, latestTag: "v0.3.0")
		state.record(tag: "v0.4.0-rc1")
		XCTAssertEqual(state.latestTag, "v0.3.0", "it does not replace a good one")
		state.record(tag: String(repeating: "9", count: 8_000_000))
		XCTAssertEqual(state.latestTag, "v0.3.0", "and a huge one is not written to preferences")
		state.record(tag: "v0.4.0")
		XCTAssertEqual(state.latestTag, "v0.4.0")
	}

	func testInstallingTheUpdateClearsTheNotice() {
		let state = UpdateState(enabled: true, lastCheck: nil, latestTag: "v0.3.0")
		XCTAssertEqual(state.notice(current: "0.2.0"), "0.3.0")
		XCTAssertNil(state.notice(current: "0.3.0"))
	}
}
