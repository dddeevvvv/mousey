import MouseyCore
import XCTest

final class FocusTests: XCTestCase {
	func testFocusGoesBackToTheAppFromBeforeTheFirstSighting() {
		var focus = FocusToRestore<String>()
		focus.secureInputSeen(frontmost: "Safari")
		focus.secureInputSeen(frontmost: "Mousey")
		XCTAssertEqual(focus.captureEnded(), "Safari", "a second sighting must not replace the app the person was using")
		XCTAssertNil(focus.captureEnded(), "and it is given back once")
	}

	func testEachCaptureStartsOver() {
		var focus = FocusToRestore<String>()
		focus.secureInputSeen(frontmost: "Safari")
		_ = focus.captureEnded()
		focus.secureInputSeen(frontmost: "Mail")
		XCTAssertEqual(focus.captureEnded(), "Mail")
	}
}
