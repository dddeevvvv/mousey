import Compression
import Foundation
import CoreGraphics

public struct WireEvent: Equatable, Sendable {
	/// Pointer position at capture, so a click lands where it was made.
	public var x, y: Double
	/// The motion counter at capture. Orders this event against the latest motion.
	public var motionSeq: UInt32
	/// `CGEvent.data`. Opaque to MouseyCore.
	public var bytes: Data

	public init(x: Double, y: Double, motionSeq: UInt32, bytes: Data) {
		self.x = x
		self.y = y
		self.motionSeq = motionSeq
		self.bytes = bytes
	}
}

/// A snapshot of what the controller wants true. A later frame carries everything still unconfirmed from an earlier one.
public struct Frame: Equatable, Sendable {
	public var session: UInt32
	public var seq: UInt32
	public var sentNanos: UInt64
	public var isRemote: Bool
	public var x, y: Double
	public var motionSeq: UInt32
	/// The bytes of the motion event numbered `motionSeq`. nil when the target already confirmed it.
	public var motion: Data?
	public var firstEventID: UInt32
	public var events: [WireEvent]
	public var repeats: [Data]

	public init(
		session: UInt32, seq: UInt32, sentNanos: UInt64, isRemote: Bool, x: Double, y: Double, motionSeq: UInt32,
		motion: Data?, firstEventID: UInt32, events: [WireEvent], repeats: [Data]
	) {
		self.session = session
		self.seq = seq
		self.sentNanos = sentNanos
		self.isRemote = isRemote
		self.x = x
		self.y = y
		self.motionSeq = motionSeq
		self.motion = motion
		self.firstEventID = firstEventID
		self.events = events
		self.repeats = repeats
	}
}

/// A snapshot of the target, sent only in reply to a frame.
public struct Ack: Equatable, Sendable {
	public var session: UInt32
	public var seq: UInt32
	public var sentNanos: UInt64
	public var nextEventID: UInt32
	public var appliedMotionSeq: UInt32
	public var controlled: Bool
	public var canInject: Bool
	/// At most 8 frames, encoded as Float64.
	public var displays: [CGRect]

	public init(
		session: UInt32, seq: UInt32, sentNanos: UInt64, nextEventID: UInt32, appliedMotionSeq: UInt32,
		controlled: Bool, canInject: Bool, displays: [CGRect]
	) {
		self.session = session
		self.seq = seq
		self.sentNanos = sentNanos
		self.nextEventID = nextEventID
		self.appliedMotionSeq = appliedMotionSeq
		self.controlled = controlled
		self.canInject = canInject
		self.displays = displays
	}
}

private struct Writer {
	var bytes: [UInt8] = []

	mutating func int<T: FixedWidthInteger>(_ v: T) {
		for k in 0..<(T.bitWidth / 8) { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * k))) }
	}
	mutating func double(_ v: Double) { int(v.bitPattern) }
	mutating func blob(_ d: Data) {
		let n = min(d.count, Int(UInt16.max))
		int(UInt16(n))
		bytes.append(contentsOf: d.prefix(n))
	}
}

/// Reads from a copy, so a `Data` slice with a nonzero start index is no different from a whole buffer.
private struct Reader {
	let bytes: [UInt8]
	var offset = 0
	var remaining: Int { bytes.count - offset }

	init(_ data: Data) { bytes = Array(data) }
	init(bytes: [UInt8]) { self.bytes = bytes }

	mutating func int<T: FixedWidthInteger>(_: T.Type) -> T? {
		let n = T.bitWidth / 8
		guard remaining >= n else { return nil }
		var v: T = 0
		for k in 0..<n { v |= T(truncatingIfNeeded: bytes[offset + k]) << (8 * k) }
		offset += n
		return v
	}
	mutating func finite() -> Double? {
		guard let bits = int(UInt64.self) else { return nil }
		let v = Double(bitPattern: bits)
		return v.isFinite ? v : nil
	}
	mutating func data(_ n: Int) -> Data? {
		guard n >= 0, remaining >= n else { return nil }
		defer { offset += n }
		return Data(bytes[offset..<offset + n])
	}
	mutating func blob() -> Data? {
		guard let n = int(UInt16.self) else { return nil }
		return data(Int(n))
	}
	mutating func header(_ magic: [UInt8]) -> Bool {
		guard let m = data(magic.count), Array(m) == magic else { return false }
		return int(UInt8.self) == Wire.version
	}
}

public enum Wire {
	public static let version: UInt8 = 2
	/// Largest datagram sent, inside a 1280-byte MTU.
	public static let maxDatagram = 1200

	private static let frameMagic: [UInt8] = [0x4B, 0x46]
	private static let ackMagic: [UInt8] = [0x4B, 0x41]
	private static let noticeMagic: [UInt8] = [0x4B, 0x56]
	private static let eventOverhead = 22
	private static let maxAckDisplays = 8

	public static func encode(_ frame: Frame) -> Data {
		var w = Writer()
		w.int(frame.session)
		w.int(frame.seq)
		w.int(frame.sentNanos)
		w.int((frame.isRemote ? 1 : 0) | (frame.motion != nil ? 2 : 0) as UInt8)
		w.double(frame.x)
		w.double(frame.y)
		w.int(frame.motionSeq)
		w.int(frame.firstEventID)
		let motion = frame.motion.map { $0.prefix(Int(UInt16.max)) } ?? Data()
		let events = frame.events.prefix(Int(UInt16.max)), repeats = frame.repeats.prefix(Int(UInt16.max))
		w.int(UInt16(motion.count))
		w.int(UInt16(events.count))
		w.int(UInt16(repeats.count))
		w.bytes += motion
		for e in events {
			w.double(e.x)
			w.double(e.y)
			w.int(e.motionSeq)
			w.blob(e.bytes)
		}
		for r in repeats { w.blob(r) }
		return Data(frameMagic + [version] + packed(w.bytes))
	}

	/// A UInt16 of the raw size, then LZ4. A raw size of 0 means the body follows as it is, for when LZ4 would not shrink it.
	/// `CGEvent.data` is mostly constant, so this fits about 3 times the events in a datagram (measured on real events).
	private static func packed(_ body: [UInt8]) -> [UInt8] {
		if !body.isEmpty, body.count <= Int(UInt16.max) {
			var out = [UInt8](repeating: 0, count: body.count)
			let n = compression_encode_buffer(&out, out.count, body, body.count, nil, COMPRESSION_LZ4_RAW)
			if n > 0, n + 2 < body.count { return [UInt8(truncatingIfNeeded: body.count), UInt8(body.count >> 8)] + out[0..<n] }
		}
		return [0, 0] + body
	}

	/// nil unless it decompresses to exactly the size it claims.
	private static func unpacked(_ r: inout Reader) -> Reader? {
		guard let rawSize = r.int(UInt16.self) else { return nil }
		guard rawSize > 0 else { return r }
		guard let source = r.data(r.remaining), !source.isEmpty else { return nil }
		var out = [UInt8](repeating: 0, count: Int(rawSize))
		let n = [UInt8](source).withUnsafeBufferPointer { compression_decode_buffer(&out, out.count, $0.baseAddress!, $0.count, nil, COMPRESSION_LZ4_RAW) }
		return n == Int(rawSize) ? Reader(bytes: out) : nil
	}

	public static func encode(_ ack: Ack) -> Data {
		var w = Writer()
		w.bytes += ackMagic
		w.int(version)
		w.int(ack.session)
		w.int(ack.seq)
		w.int(ack.sentNanos)
		w.int(ack.nextEventID)
		w.int(ack.appliedMotionSeq)
		w.int((ack.controlled ? 1 : 0) | (ack.canInject ? 2 : 0) as UInt8)
		let displays = ack.displays.prefix(maxAckDisplays)
		w.int(UInt8(displays.count))
		for r in displays {
			w.double(Double(r.minX))
			w.double(Double(r.minY))
			w.double(Double(r.width))
			w.double(Double(r.height))
		}
		return Data(w.bytes)
	}

	/// Total. Returns nil on bad magic, bad version, bad lengths, or truncation. Never traps on any input.
	public static func decodeFrame(_ data: Data) -> Frame? {
		var outer = Reader(data)
		guard outer.header(frameMagic), var r = unpacked(&outer),
			let session = r.int(UInt32.self), let seq = r.int(UInt32.self), let sent = r.int(UInt64.self),
			let flags = r.int(UInt8.self), flags & ~3 == 0,
			let x = r.finite(), let y = r.finite(),
			let motionSeq = r.int(UInt32.self), let first = r.int(UInt32.self),
			let motionLen = r.int(UInt16.self), let eventCount = r.int(UInt16.self), let repeatCount = r.int(UInt16.self),
			flags & 2 != 0 || motionLen == 0,
			Int(motionLen) + Int(eventCount) * eventOverhead + Int(repeatCount) * 2 <= r.remaining,
			let motionBytes = r.data(Int(motionLen))
		else { return nil }
		var events: [WireEvent] = []
		for _ in 0..<eventCount {
			guard let ex = r.finite(), let ey = r.finite(), let ms = r.int(UInt32.self), let bytes = r.blob() else { return nil }
			events.append(WireEvent(x: ex, y: ey, motionSeq: ms, bytes: bytes))
		}
		var repeats: [Data] = []
		for _ in 0..<repeatCount {
			guard let b = r.blob() else { return nil }
			repeats.append(b)
		}
		guard r.remaining == 0 else { return nil }
		return Frame(
			session: session, seq: seq, sentNanos: sent, isRemote: flags & 1 != 0, x: x, y: y, motionSeq: motionSeq,
			motion: flags & 2 != 0 ? motionBytes : nil, firstEventID: first, events: events, repeats: repeats)
	}

	public static func decodeAck(_ data: Data) -> Ack? {
		var r = Reader(data)
		guard r.header(ackMagic),
			let session = r.int(UInt32.self), let seq = r.int(UInt32.self), let sent = r.int(UInt64.self),
			let next = r.int(UInt32.self), let applied = r.int(UInt32.self),
			let flags = r.int(UInt8.self), flags & ~3 == 0,
			let count = r.int(UInt8.self), Int(count) <= maxAckDisplays, Int(count) * 32 == r.remaining
		else { return nil }
		var displays: [CGRect] = []
		for _ in 0..<count {
			guard let x = r.finite(), let y = r.finite(), let w = r.finite(), let h = r.finite(), w > 0, h > 0 else { return nil }
			displays.append(CGRect(x: x, y: y, width: w, height: h))
		}
		return Ack(
			session: session, seq: seq, sentNanos: sent, nextEventID: next, appliedMotionSeq: applied,
			controlled: flags & 1 != 0, canInject: flags & 2 != 0, displays: displays)
	}

	/// Sent in answer to a frame this version cannot read, so the other Mac can say what is wrong instead of "not answering".
	public static func versionNotice() -> Data { Data(noticeMagic + [version]) }

	/// The other Mac's version, from a notice.
	public static func decodeVersionNotice(_ data: Data) -> UInt8? {
		data.count == 3 && Array(data.prefix(2)) == noticeMagic ? data[data.startIndex + 2] : nil
	}

	/// True for a frame from a different version of the app, as opposed to garbage.
	public static func isFrameOfOtherVersion(_ data: Data) -> Bool {
		data.count >= 3 && Array(data.prefix(2)) == frameMagic && data[data.startIndex + 2] != version
	}

	/// Bytes of frame overhead before compression, with no motion, events, or repeats.
	public static let frameHeaderSize = 52

	/// Bytes one event takes in a frame, including its stamp and length.
	public static func encodedSize(of event: WireEvent) -> Int { eventOverhead + min(event.bytes.count, Int(UInt16.max)) }
}
