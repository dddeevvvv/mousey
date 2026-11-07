import CoreGraphics
import XCTest
import MouseyCore

final class LinkSimTests: XCTestCase {
	/// Properties 1 to 5 and 7, over many seeded links.
	func testSeededLinks() {
		var clean = 0, cut = 0, abandoned = 0, crossings = 0
		for seed in 0..<2000 {
			let sim = LinkSim(seed: UInt64(seed))
			let sessions = sim.rng.int(1...3)
			for _ in 0..<sessions {
				sim.runSession(steps: sim.rng.int(20...150), drain: sim.rng.chance(0.6))
				sim.run(for: Tick(sim.rng.int(0...1500)) * ms)
			}
			sim.settle()
			sim.verify()
			clean += sim.sessions.filter(\.drained).count
			cut += sim.sessions.filter(\.cut).count
			abandoned += sim.abandonedCount
			crossings += sim.sessions.count
		}
		print("sessions \(crossings), drained \(clean), cut \(cut), abandoned events \(abandoned)")
		XCTAssertGreaterThan(clean, 1000, "the clean-session properties would be vacuous")
		XCTAssertGreaterThan(abandoned, 1000, "the abandoned-event property would be vacuous")
	}

	/// Property 6: a permanent partition while remote, with the user still moving the pointer.
	func testPermanentPartitionReturnsControlAndReleasesTheTarget() {
		for seed in 0..<200 {
			var cond = Conditions()
			cond.delay = 2 * ms...12 * ms
			let sim = LinkSim(seed: UInt64(5000 + seed), cond: cond)
			XCTAssertTrue(sim.cross(), "seed \(seed)")
			sim.captureEvent(.keyDown, 5)
			sim.captureEvent(.modifierDown, 55)
			sim.captureEvent(.buttonDown, 0)
			sim.captureEvent(.scroll, 1, 0)
			sim.captureEvent(.gesture, 1)
			sim.run(for: 300 * ms)
			XCTAssertFalse(sim.heldEmpty, "seed \(seed): the target should be holding input")
			sim.cond.partition = sim.now..<Tick.max
			for _ in 0..<500 {
				sim.run(for: 8 * ms)
				sim.captureMotion(dx: 3, dy: 1)
			}
			XCTAssertEqual(sim.endCaptureTimes.count, 1, "seed \(seed)")
			let sinceAck = (sim.endCaptureTimes.first ?? 0) &- sim.lastAckDelivered
			XCTAssertGreaterThan(sinceAck, Tuning.targetSilentReturnNanos, "seed \(seed)")
			XCTAssertLessThanOrEqual(sinceAck, Tuning.targetSilentReturnNanos + 10 * ms, "seed \(seed): controller returned late")
			XCTAssertEqual(sim.lastReturn, .targetSilent)

			let releaseDeadline = sim.lastFrameDelivered + Tuning.targetSilentReleaseNanos + 200 * ms
			sim.run(until: releaseDeadline)
			XCTAssertTrue(sim.heldEmpty, "seed \(seed): target still holding input at its limit")
			XCTAssertLessThanOrEqual(sim.emptiedAt ?? .max, releaseDeadline, "seed \(seed)")
			let commands = sim.targetCommandCount
			sim.run(for: 6 * second)
			XCTAssertEqual(sim.targetCommandCount, commands, "seed \(seed): the target acted again with nothing arriving")
			XCTAssertEqual([sim.beginCaptureCount, sim.endCaptureTimes.count], [1, 1], "seed \(seed): the controller captured or released again")
			XCTAssertFalse(sim.isRemote)
		}
	}
}
