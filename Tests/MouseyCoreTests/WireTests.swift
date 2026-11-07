import CoreGraphics
import XCTest
import MouseyCore

final class WireTests: XCTestCase {
	private func randomFrame(_ rng: inout RNG) -> Frame {
		func blob(_ rng: inout RNG) -> Data { Data((0..<rng.int(0...60)).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
		return Frame(
			session: .random(in: 0...UInt32.max, using: &rng), seq: .random(in: 0...UInt32.max, using: &rng),
			sentNanos: .random(in: 0...UInt64.max, using: &rng), isRemote: rng.chance(0.5),
			x: rng.double(-5000...5000), y: rng.double(-5000...5000), motionSeq: .random(in: 0...UInt32.max, using: &rng),
			motion: rng.chance(0.6) ? blob(&rng) : nil, firstEventID: .random(in: 0...UInt32.max, using: &rng),
			events: (0..<rng.int(0...6)).map { _ in
				WireEvent(x: rng.double(-5000...5000), y: rng.double(-5000...5000), motionSeq: .random(in: 0...UInt32.max, using: &rng), bytes: blob(&rng))
			},
			repeats: (0..<rng.int(0...3)).map { _ in blob(&rng) })
	}

	private func randomAck(_ rng: inout RNG) -> Ack {
		Ack(
			session: .random(in: 0...UInt32.max, using: &rng), seq: .random(in: 0...UInt32.max, using: &rng),
			sentNanos: .random(in: 0...UInt64.max, using: &rng), nextEventID: .random(in: 0...UInt32.max, using: &rng),
			appliedMotionSeq: .random(in: 0...UInt32.max, using: &rng), controlled: rng.chance(0.5), canInject: rng.chance(0.5),
			displays: (0..<rng.int(0...8)).map { _ in CGRect(x: rng.double(-4000...4000), y: rng.double(-4000...4000), width: rng.double(1...4000), height: rng.double(1...4000)) })
	}

	func testFrameAndAckRoundTrip() {
		var rng = RNG(seed: 1)
		for _ in 0..<500 {
			let f = randomFrame(&rng), a = randomAck(&rng)
			XCTAssertEqual(Wire.decodeFrame(Wire.encode(f)), f)
			XCTAssertEqual(Wire.decodeAck(Wire.encode(a)), a)
		}
	}

	func testEveryTruncationOfAValidPacketIsRejected() {
		var rng = RNG(seed: 2)
		for _ in 0..<40 {
			let frame = Wire.encode(randomFrame(&rng)), ack = Wire.encode(randomAck(&rng))
			for n in 0..<frame.count { XCTAssertNil(Wire.decodeFrame(frame.prefix(n)), "frame cut to \(n)") }
			for n in 0..<ack.count { XCTAssertNil(Wire.decodeAck(ack.prefix(n)), "ack cut to \(n)") }
		}
	}

	func testTrailingBytesAreRejected() {
		var rng = RNG(seed: 3)
		XCTAssertNil(Wire.decodeFrame(Wire.encode(randomFrame(&rng)) + [0]))
		XCTAssertNil(Wire.decodeAck(Wire.encode(randomAck(&rng)) + [0]))
	}

	func testSliceWithNonzeroStartIndexDecodes() {
		var rng = RNG(seed: 4)
		let f = randomFrame(&rng), a = randomAck(&rng)
		let framed = Data([9, 9, 9]) + Wire.encode(f) + Data([7, 7])
		let slice = framed.dropFirst(3).dropLast(2)
		XCTAssertNotEqual(slice.startIndex, 0)
		XCTAssertEqual(Wire.decodeFrame(slice), f)
		XCTAssertEqual(Wire.decodeAck((Data([1, 2]) + Wire.encode(a)).dropFirst(2)), a)
		XCTAssertEqual(Wire.decodeVersionNotice((Data([1]) + Wire.versionNotice()).dropFirst()), Wire.version)
	}

	func testEachPacketTypeOnlyDecodesAsItself() {
		var rng = RNG(seed: 5)
		let frame = Wire.encode(randomFrame(&rng)), ack = Wire.encode(randomAck(&rng)), notice = Wire.versionNotice()
		XCTAssertNil(Wire.decodeAck(frame))
		XCTAssertNil(Wire.decodeFrame(ack))
		XCTAssertNil(Wire.decodeFrame(notice))
		XCTAssertNil(Wire.decodeAck(notice))
		XCTAssertNil(Wire.decodeVersionNotice(frame))
		XCTAssertNil(Wire.decodeVersionNotice(ack))
		XCTAssertEqual(Wire.decodeVersionNotice(notice), Wire.version)
	}

	func testVersionByteIsChecked() {
		var rng = RNG(seed: 6)
		var bytes = Array(Wire.encode(randomFrame(&rng)))
		XCTAssertEqual(bytes[2], Wire.version)
		bytes[2] = Wire.version + 1
		XCTAssertNil(Wire.decodeFrame(Data(bytes)))
	}

	func testCountsLargerThanTheBufferAreRejectedWithoutAllocating() {
		var bytes = Array(Wire.encode(Frame(session: 0, seq: 0, sentNanos: 0, isRemote: false, x: 0, y: 0, motionSeq: 0, motion: nil, firstEventID: 0, events: [], repeats: [])))
		let countOffset = bytes.count - 4
		bytes[countOffset] = 0xFF
		bytes[countOffset + 1] = 0xFF
		XCTAssertNil(Wire.decodeFrame(Data(bytes)))
	}

	func testNonFiniteCoordinatesAndEmptyDisplaysAreRejected() {
		var rng = RNG(seed: 7)
		var f = randomFrame(&rng)
		f.x = .nan
		XCTAssertNil(Wire.decodeFrame(Wire.encode(f)))
		var a = randomAck(&rng)
		a.displays = [CGRect(x: 0, y: 0, width: 0, height: 10)]
		XCTAssertNil(Wire.decodeAck(Wire.encode(a)))
	}

	func testAckKeepsAtMostEightDisplays() {
		var rng = RNG(seed: 8)
		var a = randomAck(&rng)
		a.displays = (0..<11).map { CGRect(x: Double($0) * 10, y: 0, width: 10, height: 10) }
		XCTAssertEqual(Wire.decodeAck(Wire.encode(a))?.displays, Array(a.displays.prefix(8)))
	}

	func testRepetitiveFramesShrinkAndRoundTrip() {
		var f = Frame(session: 1, seq: 1, sentNanos: 1, isRemote: true, x: 1, y: 1, motionSeq: 1, motion: Data(repeating: 2, count: 250), firstEventID: 1, events: [], repeats: [Data(repeating: 3, count: 30)])
		f.events = (0..<8).map { WireEvent(x: Double($0), y: 2, motionSeq: 3, bytes: Data(repeating: 1, count: 480)) }
		let encoded = Wire.encode(f)
		XCTAssertLessThan(encoded.count, Wire.maxDatagram, "8 events of 480 bytes must fit once compressed")
		XCTAssertEqual(Wire.decodeFrame(encoded), f)
	}

	func testIncompressibleFramesRoundTripAtTheirOwnSize() {
		var rng = RNG(seed: 9)
		let noise = Data((0..<900).map { _ in UInt8.random(in: 0...255, using: &rng) })
		let f = Frame(session: 1, seq: 1, sentNanos: 1, isRemote: true, x: 1, y: 1, motionSeq: 1, motion: noise, firstEventID: 1, events: [], repeats: [])
		XCTAssertEqual(Wire.decodeFrame(Wire.encode(f)), f)
		XCTAssertLessThanOrEqual(Wire.encode(f).count, Wire.frameHeaderSize + 900 + 5)
	}

	func testACompressedFrameThatLiesAboutItsSizeIsRejected() {
		let event = WireEvent(x: 1, y: 2, motionSeq: 3, bytes: Data(repeating: 1, count: 400))
		let f = Frame(session: 1, seq: 1, sentNanos: 1, isRemote: true, x: 1, y: 1, motionSeq: 1, motion: nil, firstEventID: 1, events: [event], repeats: [])
		var bytes = [UInt8](Wire.encode(f))
		XCTAssertNotEqual(bytes[3], 0)
		bytes[3] &+= 1
		XCTAssertNil(Wire.decodeFrame(Data(bytes)))
		XCTAssertNil(Wire.decodeFrame(Wire.encode(f).prefix(10)))
	}

	func testRandomAndMutatedBuffersNeverTrap() {
		var rng = RNG(seed: 99)
		let seeds = (0..<20).map { _ in (Wire.encode(randomFrame(&rng)), Wire.encode(randomAck(&rng))) }
		for i in 0..<100_000 {
			var bytes: [UInt8]
			if i % 2 == 0 {
				bytes = (0..<rng.int(0...120)).map { _ in UInt8.random(in: 0...255, using: &rng) }
				if i % 4 == 0, bytes.count > 3 { bytes[0] = 0x4B; bytes[1] = rng.chance(0.5) ? 0x46 : 0x41; bytes[2] = Wire.version }
			} else {
				let pair = seeds[rng.int(0...seeds.count - 1)]
				bytes = Array(rng.chance(0.5) ? pair.0 : pair.1)
				for _ in 0..<rng.int(1...4) where !bytes.isEmpty { bytes[rng.int(0...bytes.count - 1)] = UInt8.random(in: 0...255, using: &rng) }
				if rng.chance(0.3) { bytes.removeLast(rng.int(0...bytes.count)) }
			}
			let data = Data(bytes)
			_ = Wire.decodeFrame(data)
			_ = Wire.decodeAck(data)
			_ = Wire.decodeVersionNotice(data)
		}
	}
}
