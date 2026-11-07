import XCTest
import MouseyCore

final class KeyRouterTests: XCTestCase {
	private func routes(_ events: [EventClass]) -> [KeyRouter.Route] {
		var router = KeyRouter()
		return events.map { router.route($0) }
	}

	func testKeyPressedWhileRemoteForwardsItsRepeatsAndItsUp() {
		XCTAssertEqual(routes([.keyDown(code: 0, isRepeat: false), .keyDown(code: 0, isRepeat: true), .keyUp(code: 0)]), [.forward, .forwardAsRepeat, .forward])
	}

	func testKeyHeldBeforeCrossingKeepsRepeatingAndReleasingOnTheLocalMac() {
		XCTAssertEqual(routes([.keyDown(code: 0, isRepeat: true), .keyUp(code: 0)]), [.passToLocal, .passToLocal])
	}

	func testModifierHeldAcrossACrossingReleasesLocally() {
		XCTAssertEqual(routes([.modifier(code: 55, isDown: false)]), [.passToLocal])
	}

	func testModifierPressedWhileRemoteForwardsItsUp() {
		XCTAssertEqual(routes([.modifier(code: 55, isDown: true), .modifier(code: 55, isDown: false), .modifier(code: 55, isDown: false)]), [.forward, .forward, .passToLocal])
	}

	func testAKeyIsHeldUntilItsOwnUp() {
		XCTAssertEqual(routes([.keyDown(code: 1, isRepeat: false), .keyUp(code: 2), .keyDown(code: 1, isRepeat: true), .keyUp(code: 1), .keyDown(code: 1, isRepeat: true)],),
			[.forward, .passToLocal, .forwardAsRepeat, .forward, .passToLocal])
	}

	func testEverythingElseForwards() {
		XCTAssertEqual(routes([.button(index: 0, isDown: false), .scroll(phase: 4, momentumPhase: 0), .gesture(phase: 1, kind: 0), .other]), Array(repeating: .forward, count: 4))
	}

	func testResetForgetsHeldKeys() {
		var router = KeyRouter()
		_ = router.route(.keyDown(code: 1, isRepeat: false))
		router.reset()
		XCTAssertEqual(router.route(.keyUp(code: 1)), .passToLocal)
		XCTAssertEqual(router, KeyRouter())
	}
}
