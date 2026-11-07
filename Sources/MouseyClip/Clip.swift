import CryptoKit
import Foundation

/// One clipboard's worth of content. Only forms this app does not have to interpret: an image stays bytes here, and
/// whichever app asks the clipboard for it does the decoding.
public struct ClipItem: Equatable, Sendable {
	public enum Kind: UInt8, Sendable { case text = 1, url = 2, png = 3 }

	public static let maxTextBytes = 1_000_000
	public static let maxImageBytes = 10_000_000
	private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

	public let kind: Kind
	public let data: Data

	public init?(kind: Kind, data: Data) {
		guard !data.isEmpty, data.count <= Self.limit(for: kind) else { return nil }
		switch kind {
		case .text:
			guard let text = String(data: data, encoding: .utf8), Self.isPlain(text) else { return nil }
		case .url:
			guard let text = String(data: data, encoding: .utf8), Self.isPlain(text), Self.isWebLink(text) else { return nil }
		case .png:
			guard Array(data.prefix(Self.pngSignature.count)) == Self.pngSignature else { return nil }
		}
		self.kind = kind
		self.data = data
	}

	static func limit(for kind: Kind) -> Int { kind == .png ? maxImageBytes : maxTextBytes }

	/// A terminal acts on escape and other control characters that a person cannot see before pasting.
	private static func isPlain(_ text: String) -> Bool {
		text.unicodeScalars.allSatisfy { scalar in
			let v = scalar.value
			if v == 9 || v == 10 || v == 13 { return true }
			return v >= 0x20 && !(0x7F...0x9F).contains(v)
		}
	}

	private static func isWebLink(_ text: String) -> Bool {
		guard let colon = text.firstIndex(of: ":") else { return false }
		return ["http", "https", "mailto"].contains(text[..<colon].lowercased()) && !text.contains(where: \.isNewline)
	}
}

/// The bytes on the connection: magic, version, kind, length, content.
public enum ClipFrame {
	private static let magic: [UInt8] = [0x4B, 0x43]
	private static let version: UInt8 = 1
	static let headerSize = 8

	public enum Next: Equatable {
		case needMore
		case item(ClipItem)
		/// Nothing an honest peer sends. The caller closes the connection.
		case invalid
	}

	public static func encode(_ item: ClipItem) -> Data {
		var out = Data(magic + [version, item.kind.rawValue])
		var length = UInt32(item.data.count).littleEndian
		out.append(Data(bytes: &length, count: 4))
		out.append(item.data)
		return out
	}

	/// Takes one item off the front of `buffer`. A declared length over the limit is refused before any of it is buffered.
	public static func next(_ buffer: inout Data) -> Next {
		guard buffer.count >= headerSize else {
			return buffer.isEmpty || Array(buffer.prefix(2)) == Array(magic.prefix(min(2, buffer.count))) ? .needMore : .invalid
		}
		let header = [UInt8](buffer.prefix(headerSize))
		guard Array(header[0..<2]) == magic, header[2] == version, let kind = ClipItem.Kind(rawValue: header[3]) else { return .invalid }
		let length = Int(header[4]) | Int(header[5]) << 8 | Int(header[6]) << 16 | Int(header[7]) << 24
		guard length > 0, length <= ClipItem.limit(for: kind) else { return .invalid }
		guard buffer.count >= headerSize + length else { return .needMore }
		let body = Data(buffer.dropFirst(headerSize).prefix(length))
		buffer = Data(buffer.dropFirst(headerSize + length))
		guard let item = ClipItem(kind: kind, data: body) else { return .invalid }
		return .item(item)
	}
}

/// When content may move: only as input crosses. The keyboard Mac enforces this against a compromised controlled Mac,
/// because only its own pointer can start a crossing. A controlled Mac cannot enforce it against a compromised keyboard
/// Mac, which says when it crosses, and which could already type anything there. Times are monotonic seconds, so
/// changing the clock cannot reopen a window.
public struct ClipSession: Sendable {
	/// A large image can take a moment after the crossing on Wi-Fi.
	public static let acceptWindow: TimeInterval = 10
	/// The two connections are separate, so an item can arrive just before the frame that says the crossing happened.
	public static let earlyWindow: TimeInterval = 3

	private var lastChange: Int
	private var arrival: (at: TimeInterval, changeCount: Int)?
	private var early: (item: ClipItem, at: TimeInterval, changeCount: Int)?

	/// What is on the clipboard when sharing starts stays here. Only what is copied later can travel.
	public init(changeCount: Int) { lastChange = changeCount }

	/// Input is leaving this Mac. True when the clipboard has something new to send.
	public mutating func leaving(changeCount: Int) -> Bool {
		defer { lastChange = changeCount }
		arrival = nil
		return changeCount != lastChange
	}

	/// Input has arrived on this Mac. Returns an item that got here first.
	public mutating func arriving(now: TimeInterval, changeCount: Int) -> ClipItem? {
		defer { early = nil }
		if let early, now - early.at <= Self.earlyWindow, early.changeCount == changeCount {
			arrival = nil
			return early.item
		}
		arrival = (now, changeCount)
		return nil
	}

	/// An item arrived. Returns it if it may go on the clipboard. One per crossing, and never over something the
	/// person copied here since the crossing.
	public mutating func receive(_ item: ClipItem, now: TimeInterval, changeCount: Int) -> ClipItem? {
		if let current = arrival {
			arrival = nil
			if now - current.at <= Self.acceptWindow, current.changeCount == changeCount { return item }
			return nil
		}
		early = (item, now, changeCount)
		return nil
	}

	/// The clipboard was just written with a received item, so it must not be sent back.
	public mutating func applied(changeCount: Int) { lastChange = changeCount }
}

/// Its own key, so the two connections never share one.
public func clipboardKey(fromLinkKey key: Data) -> Data {
	HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), info: Data("mousey clipboard key v1".utf8), outputByteCount: 32)
		.withUnsafeBytes { Data($0) }
}
