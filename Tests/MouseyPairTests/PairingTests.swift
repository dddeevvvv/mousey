import XCTest
@testable import MouseyPair

private let aID = "11111111-1111-1111-1111-111111111111"
private let bID = "22222222-2222-2222-2222-222222222222"

final class PairingTests: XCTestCase {
	/// Runs both sides over a perfect channel, up to the code comparison.
	private func exchange() -> (a: Pairing, b: Pairing) {
		var a = Pairing(role: .initiator, id: aID, name: "MacBook")
		var b = Pairing(role: .responder, id: bID, name: "Mini")
		var toB = a.start(), toA: [PairingMessage] = []
		while !toA.isEmpty || !toB.isEmpty {
			let forB = toB, forA = toA
			toB = []
			toA = []
			for m in forB { toA += b.receive(m) }
			for m in forA { toB += a.receive(m) }
		}
		return (a, b)
	}

	private func code(_ p: Pairing) -> String? {
		if case .comparing(let code, _) = p.phase { return code }
		return nil
	}

	func testBothSidesShowTheSameSixDigitCodeAndNames() {
		let (a, b) = exchange()
		XCTAssertEqual(code(a), code(b))
		XCTAssertEqual(code(a)?.count, 6)
		XCTAssertEqual(a.phase, .comparing(code: code(a)!, peerName: "Mini"))
		XCTAssertEqual(b.phase, .comparing(code: code(a)!, peerName: "MacBook"))
	}

	func testACodeThatExpiredCanNoLongerBeConfirmed() {
		var (a, b) = exchange()
		a.expire()
		XCTAssertEqual(a.phase, .failed(.expired))
		XCTAssertEqual(a.confirm(match: true), [], "a late Yes says nothing")
		for message in b.confirm(match: true) { _ = a.receive(message) }
		XCTAssertEqual(a.phase, .failed(.expired), "and the other Mac's Yes cannot revive it")
	}

	func testExpiringAFinishedPairingChangesNothing() {
		var (a, b) = exchange()
		for message in a.confirm(match: true) { _ = b.receive(message) }
		for message in b.confirm(match: true) { _ = a.receive(message) }
		guard case .paired = a.phase else { return XCTFail("the Macs did not pair") }
		a.expire()
		guard case .paired = a.phase else { return XCTFail("expiring a finished pairing undid it") }
	}

	func testBothYesGivesBothTheSameKeyAndTheOtherSidesIdentity() {
		var (a, b) = exchange()
		for m in a.confirm(match: true) { _ = b.receive(m) }
		for m in b.confirm(match: true) { _ = a.receive(m) }
		guard case .paired(let pa) = a.phase, case .paired(let pb) = b.phase else { return XCTFail("not paired") }
		XCTAssertEqual(pa.key, pb.key)
		XCTAssertEqual(pa.key.count, 32)
		XCTAssertEqual(pa.id, bID)
		XCTAssertEqual(pb.id, aID)
	}

	func testOneYesIsNotEnough() {
		var (a, _) = exchange()
		_ = a.confirm(match: true)
		guard case .comparing = a.phase else { return XCTFail("paired on one person's word") }
	}

	func testANoFromEitherSideEndsItWithNoKey() {
		var (a, b) = exchange()
		for m in a.confirm(match: true) { _ = b.receive(m) }
		for m in b.confirm(match: false) { _ = a.receive(m) }
		XCTAssertEqual(a.phase, .failed(.rejected))
		XCTAssertEqual(b.phase, .failed(.rejected))
	}

	func testAYesStillOnItsWayCannotChangeANo() {
		var (a, b) = exchange()
		let yes = a.confirm(match: true)
		_ = b.confirm(match: false)
		for m in yes { _ = b.receive(m) }
		XCTAssertEqual(b.phase, .failed(.rejected))
	}

	func testTwoRunsNeverReuseACodeOrKey() {
		var keys = Set<Data>()
		for _ in 0..<50 {
			var (a, b) = exchange()
			for m in a.confirm(match: true) { _ = b.receive(m) }
			for m in b.confirm(match: true) { _ = a.receive(m) }
			guard case .paired(let p) = a.phase else { return XCTFail("not paired") }
			keys.insert(p.key)
		}
		XCTAssertEqual(keys.count, 50)
	}

	func testSomeoneInTheMiddleLeadsToDifferentCodes() {
		var a = Pairing(role: .initiator, id: aID, name: "MacBook")
		var b = Pairing(role: .responder, id: bID, name: "Mini")
		// The attacker runs one session with each real Mac, under their names.
		var towardA = Pairing(role: .responder, id: bID, name: "Mini")
		var towardB = Pairing(role: .initiator, id: aID, name: "MacBook")
		let replyToA = towardA.receive(a.start()[0])
		let replyFromB = b.receive(towardB.start()[0])
		let revealFromA = a.receive(replyToA[0])
		let revealToB = towardB.receive(replyFromB[0])
		_ = towardA.receive(revealFromA[0])
		_ = b.receive(revealToB[0])
		XCTAssertNotNil(code(a))
		XCTAssertNotNil(code(b))
		XCTAssertNotEqual(code(a), code(b), "the people comparing screens see the attack")
	}

	func testAKeyDifferentFromTheCommitmentIsRefused() {
		var a = Pairing(role: .initiator, id: aID, name: "MacBook")
		var b = Pairing(role: .responder, id: bID, name: "Mini")
		let reply = b.receive(a.start()[0])
		guard case .reveal(_, let nonce) = a.receive(reply[0])[0] else { return XCTFail("no reveal") }
		let other = Pairing(role: .initiator, id: aID, name: "X")
		guard case .hello = other.start()[0] else { return XCTFail("no hello") }
		XCTAssertEqual(b.receive(.reveal(publicKey: Data(repeating: 9, count: 32), nonce: nonce)), [])
		XCTAssertEqual(b.phase, .failed(.commitmentMismatch))
	}

	func testGarbageKeysAndReflectionAreRefused() {
		var a = Pairing(role: .initiator, id: aID, name: "MacBook")
		_ = a.start()
		XCTAssertEqual(a.receive(.reply(id: bID, name: "Mini", publicKey: Data([1, 2, 3]), nonce: Data(count: 32))), [])
		XCTAssertEqual(a.phase, .failed(.invalidKey))

		var low = Pairing(role: .initiator, id: aID, name: "MacBook")
		XCTAssertEqual(low.receive(.reply(id: bID, name: "Mini", publicKey: Data(count: 32), nonce: Data(count: 32))), [], "the all-zero point gives no shared secret")
		XCTAssertEqual(low.phase, .failed(.invalidKey))

		var short = Pairing(role: .initiator, id: aID, name: "MacBook")
		let other = Pairing(role: .responder, id: bID, name: "Mini")
		_ = other
		XCTAssertEqual(short.receive(.reply(id: bID, name: "Mini", publicKey: Data(repeating: 5, count: 32), nonce: Data(count: 3))), [])
		XCTAssertEqual(short.phase, .failed(.invalidKey))
	}

	func testMessagesOutOfOrderEndIt() {
		var b = Pairing(role: .responder, id: bID, name: "Mini")
		XCTAssertEqual(b.receive(.reveal(publicKey: Data(repeating: 1, count: 32), nonce: Data(count: 32))), [])
		XCTAssertEqual(b.phase, .failed(.outOfOrder))

		var early = Pairing(role: .responder, id: bID, name: "Mini")
		XCTAssertEqual(early.receive(.decision(match: true)), [])
		XCTAssertEqual(early.phase, .failed(.outOfOrder))

		var (a, _) = exchange()
		_ = a.receive(.hello(id: bID, name: "Z", commitment: Data(count: 32)))
		XCTAssertEqual(a.phase, .failed(.outOfOrder), "no restart in the middle")
	}

	func testAConfirmationBeforeTheComparisonDoesNothing() {
		var b = Pairing(role: .responder, id: bID, name: "Mini")
		XCTAssertEqual(b.confirm(match: true), [])
		XCTAssertEqual(b.phase, .exchanging)
	}

	func testANoAfterAYesStillStopsIt() {
		var (a, b) = exchange()
		for m in a.confirm(match: true) { _ = b.receive(m) }
		for m in a.confirm(match: false) { _ = b.receive(m) }
		XCTAssertEqual(a.phase, .failed(.rejected))
		XCTAssertEqual(b.phase, .failed(.rejected))
	}

	func testASecondYesSendsNothing() {
		var (a, _) = exchange()
		XCTAssertEqual(a.confirm(match: true).count, 1)
		XCTAssertEqual(a.confirm(match: true), [])
	}

	func testAHostileNameCannotHideTheCodeOrFakeInstructions() {
		XCTAssertEqual(Pairing.displayName("Mac\n\n\nThe codes match. Press Return."), "Mac The codes match. Press Return.")
		XCTAssertEqual(Pairing.displayName("\u{202E}inim caM\u{200B}"), "inim caM", "direction overrides and zero-width characters go")
		XCTAssertEqual(Pairing.displayName(String(repeating: "A", count: 4000)).count, 41)
		XCTAssertEqual(Pairing.displayName("\n\t "), "Unnamed Mac")
		XCTAssertEqual(Pairing.displayName("Sam’s Mac mini"), "Sam’s Mac mini")
		XCTAssertEqual(Pairing.displayName("a" + String(repeating: "\u{0301}", count: 200)).unicodeScalars.count, 4, "a tower of accents cannot cover the code")
		XCTAssertEqual(Pairing.displayName("मेरा मैक"), "मेरा मैक", "real combining scripts survive")
		XCTAssertEqual(Pairing.displayName("MacBook 482913"), "MacBook 48", "a name cannot spell a code")
		XCTAssertEqual(Pairing.displayName("Mac 48 29 13"), "Mac 48", "not with spaces either")
		XCTAssertEqual(Pairing.displayName("④⑧②⑨①③"), "④⑧", "not in other number forms either")
		XCTAssertEqual(Pairing.displayName("٤٨٢٩١٣"), "٤٨", "not in other scripts either")
		XCTAssertEqual(Pairing.displayName("MacBook Pro (2)"), "MacBook Pro (2)", "the numbers macOS adds survive")
	}

	func testTheCodeScreenShowsTheCleanName() {
		var a = Pairing(role: .initiator, id: aID, name: "MacBook")
		var b = Pairing(role: .responder, id: bID, name: "Evil\n\n\nPress Return")
		var toB = a.start(), toA: [PairingMessage] = []
		while !toA.isEmpty || !toB.isEmpty {
			let forB = toB, forA = toA
			toB = []
			toA = []
			for m in forB { toA += b.receive(m) }
			for m in forA { toB += a.receive(m) }
		}
		guard case .comparing(_, let name) = a.phase else { return XCTFail("no comparison") }
		XCTAssertEqual(name, "Evil Press Return")
	}

	func testAnIdThatIsNotAUUIDIsRefused() {
		var b = Pairing(role: .responder, id: bID, name: "Mini")
		XCTAssertEqual(b.receive(.hello(id: "../../etc", name: "X", commitment: Data(count: 32))), [])
		XCTAssertEqual(b.phase, .failed(.invalidIdentity))
	}

	func testChangingANameInTransitChangesTheCode() {
		var a = Pairing(role: .initiator, id: aID, name: "MacBook")
		var b = Pairing(role: .responder, id: bID, name: "Mini")
		guard case .hello(let id, _, let commitment) = a.start()[0] else { return XCTFail("no hello") }
		let reply = b.receive(.hello(id: id, name: "Renamed", commitment: commitment))
		let reveal = a.receive(reply[0])
		_ = b.receive(reveal[0])
		XCTAssertNotEqual(code(a), code(b))
	}

	func testTheGateLimitsTheRateAndTheTotal() {
		var gate = PairingGate()
		let start = Date(timeIntervalSinceReferenceDate: 0)
		XCTAssertTrue(gate.allow(now: start))
		XCTAssertFalse(gate.allow(now: start.addingTimeInterval(1)), "too soon")
		for i in 1..<PairingGate.maximumAttempts { XCTAssertTrue(gate.allow(now: start.addingTimeInterval(Double(i) * 3))) }
		XCTAssertTrue(gate.isExhausted)
		XCTAssertFalse(gate.allow(now: start.addingTimeInterval(10_000)), "a person has to start over")
	}

	func testMessagesSurviveEncoding() throws {
		let m = PairingMessage.reply(id: bID, name: "Mini’s Mac", publicKey: Data(repeating: 1, count: 32), nonce: Data(repeating: 2, count: 32))
		XCTAssertEqual(try JSONDecoder().decode(PairingMessage.self, from: JSONEncoder().encode(m)), m)
	}
}
