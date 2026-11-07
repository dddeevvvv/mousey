import CoreGraphics
import XCTest
import MouseyCore

final class GeometryTests: XCTestCase {
	private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

	func testOppositeEdges() {
		XCTAssertEqual(Edge.allCases.map(\.opposite), [.right, .left, .bottom, .top])
	}

	func testEmptyDisplaysFallBackToOneFrame() {
		XCTAssertEqual(Displays([]).frames, [CGRect(x: 0, y: 0, width: 1, height: 1)])
	}

	// A smaller display offset below the main one, and one to the left in negative coordinates.
	private var layout: Displays {
		Displays([main, CGRect(x: 1440, y: 300, width: 1000, height: 600), CGRect(x: -1920, y: -180, width: 1920, height: 1080)])
	}

	func testDisplayContainingPointAndNearest() {
		XCTAssertEqual(layout.display(containing: CGPoint(x: 100, y: 100)), main)
		XCTAssertEqual(layout.display(containing: CGPoint(x: -5, y: 100)), layout.frames[2])
		XCTAssertEqual(layout.display(containing: CGPoint(x: 1500, y: 400)), layout.frames[1])
		XCTAssertEqual(layout.display(containing: CGPoint(x: 1500, y: 100)), main, "above the small display, the main one is nearer")
		XCTAssertEqual(layout.display(containing: CGPoint(x: 3000, y: 500)), layout.frames[1])
	}

	func testInnerEdgeIsNotOuterWhereAnotherDisplayAdjoins() {
		XCTAssertFalse(layout.isOuter(.right, of: main, at: CGPoint(x: 1439, y: 500)))
		XCTAssertTrue(layout.isOuter(.right, of: main, at: CGPoint(x: 1439, y: 100)), "no display past the right edge above y 300")
		XCTAssertFalse(layout.isOuter(.left, of: main, at: CGPoint(x: 1, y: 500)))
		XCTAssertTrue(layout.isOuter(.top, of: main, at: CGPoint(x: 700, y: 0)))
		XCTAssertTrue(layout.isOuter(.bottom, of: main, at: CGPoint(x: 700, y: 899)))
		XCTAssertTrue(layout.isOuter(.left, of: layout.frames[2], at: CGPoint(x: -1919, y: 0)))
	}

	func testMoveUsesDestinationOnAnyDisplay() {
		let m = layout.move(from: CGPoint(x: 1430, y: 500), dx: 20, dy: 0)
		XCTAssertEqual(m.point, CGPoint(x: 1450, y: 500))
		XCTAssertEqual(m.overshoot, Overshoot(left: 0, right: 0, top: 0, bottom: 0))
	}

	func testMoveClampsAtOuterEdgeAndReportsOvershoot() {
		let m = layout.move(from: CGPoint(x: 1430, y: 100), dx: 25, dy: -130)
		XCTAssertEqual(m.point.x, 1440, accuracy: 1e-9)
		XCTAssertEqual(m.point.y, 0, accuracy: 1e-9)
		XCTAssertEqual(m.overshoot[.right], 15, accuracy: 1e-9)
		XCTAssertEqual(m.overshoot[.top], 30, accuracy: 1e-9)
		XCTAssertEqual(m.overshoot[.left], 0)
		XCTAssertEqual(m.overshoot[.bottom], 0)
	}

	func testMoveIgnoresNonFiniteDeltas() {
		XCTAssertEqual(laptop.move(from: CGPoint(x: 5, y: 5), dx: .nan, dy: .infinity).point, CGPoint(x: 5, y: 5))
	}

	func testFractionRoundTripsAcrossDisplaysOfDifferentSize() {
		let small = main, big = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
		let d = Displays([small, big])
		for edge in Edge.allCases {
			for f in [Float(0), 0.1, 0.5, 0.9, 1] {
				let there = d.point(on: edge, of: big, fraction: f, inset: 1)
				XCTAssertEqual(d.fraction(of: there, along: edge, on: big), f, accuracy: 1e-6, "\(edge) \(f)")
				let back = d.point(on: edge, of: small, fraction: d.fraction(of: there, along: edge, on: big), inset: 2)
				XCTAssertEqual(d.fraction(of: back, along: edge, on: small), f, accuracy: 1e-6, "\(edge) \(f) back")
			}
		}
	}

	func testWholeEdgeMapsToWholeEdge() {
		let d = Displays([main])
		XCTAssertEqual(d.point(on: .right, of: main, fraction: 0, inset: 2).y, 0, accuracy: 1e-9)
		XCTAssertEqual(d.point(on: .right, of: main, fraction: 1, inset: 2).y, 900, accuracy: 1e-9)
		XCTAssertEqual(d.point(on: .right, of: main, fraction: 0.5, inset: 2), CGPoint(x: 1438, y: 450))
		XCTAssertEqual(d.point(on: .left, of: main, fraction: 0.5, inset: 1), CGPoint(x: 1, y: 450))
		XCTAssertEqual(d.point(on: .top, of: main, fraction: 0.25, inset: 2), CGPoint(x: 360, y: 2))
		XCTAssertEqual(d.point(on: .bottom, of: main, fraction: 0.25, inset: 2), CGPoint(x: 360, y: 898))
	}

	func testPointOnEdgeStaysOnTheDisplay() {
		let p = laptop.point(on: .right, of: main, fraction: 1, inset: 0)
		XCTAssertEqual(laptop.display(containing: p), main)
		XCTAssertTrue(main.contains(p))
	}

	func testEntryDisplayIsOutermostThenLongest() {
		let stacked = Displays([CGRect(x: 0, y: 0, width: 1000, height: 600), CGRect(x: 0, y: 600, width: 800, height: 900), CGRect(x: 1000, y: 0, width: 500, height: 500)])
		XCTAssertEqual(stacked.entryDisplay(for: .left), stacked.frames[1], "tied at x 0, the taller wins")
		XCTAssertEqual(stacked.entryDisplay(for: .right), stacked.frames[2])
		XCTAssertEqual(stacked.entryDisplay(for: .top), stacked.frames[0], "tied at y 0, the wider of the first two wins")
		XCTAssertEqual(stacked.entryDisplay(for: .bottom), stacked.frames[1])
		XCTAssertEqual(layout.entryDisplay(for: .left), layout.frames[2], "negative coordinates are outermost on the left")
	}

	// MARK: EdgePush

	func testPushNeedsTenPointsAfterTheMinimumTime() {
		var push = EdgePush()
		XCTAssertFalse(push.feed(outward: 4, now: 0))
		XCTAssertFalse(push.feed(outward: 5, now: 90 * ms), "enough time, but only 9 points")
		XCTAssertTrue(push.feed(outward: 1, now: 100 * ms))
		XCTAssertFalse(push.feed(outward: 4, now: 110 * ms), "it starts over after firing")
	}

	// Recorded on a real MacBook: a push reports 50 to 100 points per event at the screen edge, about 8 ms apart.
	func testAFlickAtTheEdgeDoesNotFireBeforeTheMinimumTime() {
		var push = EdgePush()
		for i: Tick in 0..<10 { XCTAssertFalse(push.feed(outward: 100, now: i * 8 * ms), "at \(i * 8) ms") }
		XCTAssertTrue(push.feed(outward: 100, now: 80 * ms))
	}

	func testPauseResetsPush() {
		var push = EdgePush()
		XCTAssertFalse(push.feed(outward: 9, now: 0))
		XCTAssertFalse(push.feed(outward: 9, now: 251 * ms), "the 9 points before the pause are forgotten")
		XCTAssertFalse(push.feed(outward: 1, now: 252 * ms), "the minimum time restarted after the pause")
		XCTAssertTrue(push.feed(outward: 1, now: 331 * ms))
	}

	func testSlowPushStillCrosses() {
		var push = EdgePush()
		var fired = 0
		for i in 0..<10 where push.feed(outward: 1, now: Tick(i) * 200 * ms) { fired = i + 1 }
		XCTAssertEqual(fired, 10)
	}

	func testResetClearsPush() {
		var push = EdgePush()
		_ = push.feed(outward: 9, now: 0)
		push.reset()
		XCTAssertFalse(push.feed(outward: 9, now: ms))
	}
}
