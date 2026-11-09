import XCTest
@testable import MouseyClip

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
private func text(_ s: String) -> ClipItem { ClipItem(kind: .text, data: Data(s.utf8))! }

final class ClipItemTests: XCTestCase {
	func testOnlyWellFormedContentIsAnItem() {
		XCTAssertNotNil(ClipItem(kind: .text, data: Data("hello".utf8)))
		XCTAssertNotNil(ClipItem(kind: .png, data: png))
		XCTAssertNil(ClipItem(kind: .text, data: Data()), "empty")
		XCTAssertNil(ClipItem(kind: .text, data: Data([0xFF, 0xFE])), "not UTF-8")
		XCTAssertNil(ClipItem(kind: .png, data: Data("not an image".utf8)), "not a PNG")
		XCTAssertNil(ClipItem(kind: .text, data: Data(repeating: 65, count: ClipItem.maxTextBytes + 1)))
		XCTAssertNil(ClipItem(kind: .png, data: png + Data(repeating: 0, count: ClipItem.maxImageBytes)))
	}

	func testTextAKeyboardCouldNotTypeIsRefused() {
		XCTAssertNotNil(ClipItem(kind: .text, data: Data("two\nlines\tand a tab\r\n".utf8)))
		XCTAssertNotNil(ClipItem(kind: .text, data: Data("नमस्ते héllo 🙂".utf8)))
		XCTAssertNil(ClipItem(kind: .text, data: Data("safe\u{1B}[201~rm -rf ~".utf8)), "an escape can break out of a terminal's paste protection")
		XCTAssertNil(ClipItem(kind: .text, data: Data("a\u{7}b".utf8)))
		XCTAssertNil(ClipItem(kind: .text, data: Data("a\u{9B}b".utf8)))
	}

	func testOnlyWebLinksAreLinks() {
		for good in ["https://example.com/", "http://a.b", "HTTPS://A.B", "mailto:me@example.com"] { XCTAssertNotNil(ClipItem(kind: .url, data: Data(good.utf8)), good) }
		for bad in ["javascript:alert(1)", "file:///etc/hosts", "x-apple.systempreferences:foo", "no scheme", "https://a.b\nrm -rf ~"] { XCTAssertNil(ClipItem(kind: .url, data: Data(bad.utf8)), bad) }
	}
}

final class ClipFrameTests: XCTestCase {
	func testRoundTripEveryKind() {
		for item in [text("héllo"), ClipItem(kind: .url, data: Data("https://example.com".utf8))!, ClipItem(kind: .png, data: png)!] {
			var buffer = ClipFrame.encode(item)
			XCTAssertEqual(ClipFrame.next(&buffer), .item(item))
			XCTAssertTrue(buffer.isEmpty)
		}
	}

	func testArrivingOneByteAtATimeAndBackToBack() {
		let bytes = ClipFrame.encode(text("first")) + ClipFrame.encode(text("second"))
		var buffer = Data()
		var seen: [ClipItem] = []
		for byte in bytes {
			buffer.append(byte)
			if case .item(let item) = ClipFrame.next(&buffer) { seen.append(item) }
		}
		XCTAssertEqual(seen, [text("first"), text("second")])
		XCTAssertTrue(buffer.isEmpty)
	}

	func testAnOversizedLengthIsRefusedBeforeItsContentArrives() {
		var buffer = Data([0x4B, 0x43, 1, 1, 0xFF, 0xFF, 0xFF, 0x7F])
		XCTAssertEqual(ClipFrame.next(&buffer), .invalid)
	}

	func testGarbageVersionKindAndEmptyAreInvalid() {
		var wrongMagic = Data("GET / HTTP/1.1".utf8)
		XCTAssertEqual(ClipFrame.next(&wrongMagic), .invalid)
		var shortWrong = Data([0x00])
		XCTAssertEqual(ClipFrame.next(&shortWrong), .invalid)
		var wrongVersion = Data([0x4B, 0x43, 9, 1, 1, 0, 0, 0, 65])
		XCTAssertEqual(ClipFrame.next(&wrongVersion), .invalid)
		var wrongKind = Data([0x4B, 0x43, 1, 99, 1, 0, 0, 0, 65])
		XCTAssertEqual(ClipFrame.next(&wrongKind), .invalid)
		var empty = Data([0x4B, 0x43, 1, 1, 0, 0, 0, 0])
		XCTAssertEqual(ClipFrame.next(&empty), .invalid)
		var notUTF8 = Data([0x4B, 0x43, 1, 1, 2, 0, 0, 0, 0xFF, 0xFE])
		XCTAssertEqual(ClipFrame.next(&notUTF8), .invalid)
	}

	func testRandomBytesNeverTrap() {
		var rng = SystemRandomNumberGenerator()
		for _ in 0..<5000 {
			var buffer = Data((0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
			_ = ClipFrame.next(&buffer)
		}
	}

	func testASliceWithANonzeroStartDecodes() {
		var buffer = (Data([9, 9]) + ClipFrame.encode(text("x"))).dropFirst(2)
		XCTAssertEqual(ClipFrame.next(&buffer), .item(text("x")))
	}
}

final class ClipSessionTests: XCTestCase {
	private let t0: TimeInterval = 1000

	func testWhatWasCopiedBeforeSharingStartedStaysHere() {
		var s = ClipSession(changeCount: 5)
		XCTAssertFalse(s.leaving(changeCount: 5))
		XCTAssertTrue(s.leaving(changeCount: 6))
		XCTAssertFalse(s.leaving(changeCount: 6), "already sent")
	}

	func testNothingIsAcceptedWithoutACrossing() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.receive(text("planted"), now: t0, changeCount: 0))
		XCTAssertNil(s.arriving(now: t0 + ClipSession.earlyWindow + 1, changeCount: 0), "too old to belong to this crossing")
	}

	func testOnlyOneItemPerCrossing() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.arriving(now: t0, changeCount: 0))
		XCTAssertEqual(s.receive(text("first"), now: t0 + 1, changeCount: 0), text("first"))
		XCTAssertNil(s.receive(text("second"), now: t0 + 2, changeCount: 1), "a peer cannot keep rewriting the clipboard")
	}

	func testTheWindowCloses() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.arriving(now: t0, changeCount: 0))
		XCTAssertNil(s.receive(text("late"), now: t0 + ClipSession.acceptWindow + 1, changeCount: 0))
	}

	func testALateItemNeverReplacesWhatThePersonJustCopied() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.arriving(now: t0, changeCount: 0))
		XCTAssertNil(s.receive(text("slow image"), now: t0 + 5, changeCount: 1))
	}

	func testLeavingClosesTheWindow() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.arriving(now: t0, changeCount: 0))
		_ = s.leaving(changeCount: 0)
		XCTAssertNil(s.receive(text("swap"), now: t0 + 1, changeCount: 0), "input has gone, so nothing lands behind the person")
	}

	func testAnItemThatBeatsItsCrossingStillLands() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.receive(text("early"), now: t0, changeCount: 0))
		XCTAssertEqual(s.arriving(now: t0 + 0.05, changeCount: 0), text("early"))
		XCTAssertNil(s.receive(text("another"), now: t0 + 0.1, changeCount: 1), "that was this crossing's one item")
	}

	func testAnEarlyItemCannotReplaceACopyMadeSinceItArrived() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.receive(text("early"), now: t0, changeCount: 0))
		XCTAssertNil(s.arriving(now: t0 + 0.05, changeCount: 1))
	}

	func testAnItemFromBeforeInputLeftIsNotAppliedOnReturn() {
		var s = ClipSession(changeCount: 0)
		XCTAssertNil(s.receive(text("sent outside a crossing"), now: t0, changeCount: 0))
		_ = s.leaving(changeCount: 0)
		XCTAssertNil(s.arriving(now: t0 + 1, changeCount: 0), "input left after it arrived, so it belongs to no crossing")
	}

	func testAWrittenItemIsNotSentBack() {
		var s = ClipSession(changeCount: 1)
		s.applied(changeCount: 2)
		XCTAssertFalse(s.leaving(changeCount: 2))
	}
}

final class ClipKeyTests: XCTestCase {
	func testTheClipboardKeyDiffersFromTheLinkKeyAndIsStable() {
		let link = Data(repeating: 7, count: 32)
		XCTAssertNotEqual(clipboardKey(fromLinkKey: link), link)
		XCTAssertEqual(clipboardKey(fromLinkKey: link), clipboardKey(fromLinkKey: link))
		XCTAssertEqual(clipboardKey(fromLinkKey: link).count, 32)
		XCTAssertNotEqual(clipboardKey(fromLinkKey: link), clipboardKey(fromLinkKey: Data(repeating: 8, count: 32)))
	}
}
