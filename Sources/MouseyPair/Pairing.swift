import CryptoKit
import Foundation

/// What the two Macs say to each other while pairing, over a connection that nobody should trust yet.
public enum PairingMessage: Codable, Equatable, Sendable {
	case hello(id: String, name: String, commitment: Data)
	case reply(id: String, name: String, publicKey: Data, nonce: Data)
	case reveal(publicKey: Data, nonce: Data)
	case decision(match: Bool)
}

public struct PairedPeer: Equatable, Sendable {
	public let id: String
	public let name: String
	/// The 32-byte key the encrypted link uses from now on.
	public let key: Data
}

public enum PairingFailure: Equatable, Sendable {
	/// The initiator's key does not match what it committed to, which is what tampering looks like.
	case commitmentMismatch
	case invalidKey
	/// The other side's id is not the form every Mac generates.
	case invalidIdentity
	case outOfOrder
	case rejected
	/// Nobody answered the code in time.
	case expired
}

/// Pairing, as a state machine with no network in it.
///
/// Anyone on the network can reach this exchange, so it proves nothing by itself. A person proves it by comparing a
/// 6-digit code on both screens. The initiator commits to its key before it sees the responder's, so someone in the
/// middle has to choose keys before knowing what code they lead to, and gets one chance in a million per attempt.
/// The code is never the key: a key built from 6 digits could be cracked offline from a recording of the link.
public struct Pairing: Sendable {
	public enum Role: Sendable { case initiator, responder }
	public enum Phase: Equatable, Sendable {
		case exchanging
		case comparing(code: String, peerName: String)
		case paired(PairedPeer)
		case failed(PairingFailure)
	}

	public private(set) var phase = Phase.exchanging
	private let role: Role
	private let id: String
	private let name: String
	private let secret = Curve25519.KeyAgreement.PrivateKey()
	private let nonce: Data
	private var peerID: String?
	/// As sent, because the code covers it. Only `displayName` is ever shown.
	private var peerName: String?
	private var peerCommitment: Data?
	private var peerKey: Data?
	private var peerNonce: Data?
	private var derivedKey: Data?
	private var localMatch: Bool?
	private var remoteMatch: Bool?

	public init(role: Role, id: String, name: String) {
		self.role = role
		self.id = id
		self.name = name
		var bytes = [UInt8](repeating: 0, count: 32)
		precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
		nonce = Data(bytes)
	}

	private var publicKey: Data { secret.publicKey.rawRepresentation }

	/// The initiator's first message. The responder has nothing to say first.
	public func start() -> [PairingMessage] {
		guard role == .initiator else { return [] }
		return [.hello(id: id, name: name, commitment: Self.commitment(publicKey, nonce))]
	}

	public mutating func receive(_ message: PairingMessage) -> [PairingMessage] {
		// A finished pairing stays as it finished. The other Mac's answer may still have been on its way.
		switch phase {
		case .paired, .failed: return []
		case .exchanging, .comparing: break
		}
		switch (role, message, peerID == nil, peerKey == nil) {
		case (.responder, .hello(let id, let name, let commitment), true, true):
			guard UUID(uuidString: id) != nil else { return fail(.invalidIdentity) }
			peerID = id
			peerName = name
			peerCommitment = commitment
			return [.reply(id: self.id, name: self.name, publicKey: publicKey, nonce: nonce)]
		case (.initiator, .reply(let id, let name, let key, let nonce), true, true):
			guard UUID(uuidString: id) != nil else { return fail(.invalidIdentity) }
			peerID = id
			peerName = name
			guard complete(peerKey: key, peerNonce: nonce) else { return [] }
			return [.reveal(publicKey: publicKey, nonce: self.nonce)]
		case (.responder, .reveal(let key, let nonce), false, true):
			guard peerCommitment == Self.commitment(key, nonce) else {
				phase = .failed(.commitmentMismatch)
				return []
			}
			_ = complete(peerKey: key, peerNonce: nonce)
			return []
		case (_, .decision(let match), false, false):
			guard case .comparing = phase else { return fail(.outOfOrder) }
			remoteMatch = match
			settle()
			return []
		default:
			return fail(.outOfOrder)
		}
	}

	/// What the person decided after comparing the codes. Nothing is usable until both people say yes.
	public mutating func confirm(match: Bool) -> [PairingMessage] {
		// A later No still counts. Only a second Yes is a repeat.
		guard case .comparing = phase, localMatch == nil || !match else { return [] }
		localMatch = match
		settle()
		return [.decision(match: match)]
	}

	/// A code left on a screen is a standing invitation to press Yes by mistake.
	public mutating func expire() {
		guard case .comparing = phase else { return }
		phase = .failed(.expired)
	}

	private mutating func fail(_ failure: PairingFailure) -> [PairingMessage] {
		phase = .failed(failure)
		return []
	}

	private mutating func settle() {
		if localMatch == false || remoteMatch == false {
			phase = .failed(.rejected)
		} else if localMatch == true, remoteMatch == true, let peerID, let peerName, let derivedKey {
			phase = .paired(PairedPeer(id: peerID, name: Self.displayName(peerName), key: derivedKey))
		}
	}

	private mutating func complete(peerKey key: Data, peerNonce: Data) -> Bool {
		guard key != publicKey, peerNonce.count == 32, let peerID, let peerName,
			let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key),
			let shared = try? secret.sharedSecretFromKeyAgreement(with: theirs) else {
			phase = .failed(.invalidKey)
			return false
		}
		self.peerKey = key
		self.peerNonce = peerNonce
		let isInitiator = role == .initiator
		let transcript = Self.transcript(
			initiatorID: isInitiator ? id : peerID, responderID: isInitiator ? peerID : id,
			initiatorName: isInitiator ? name : peerName, responderName: isInitiator ? peerName : name,
			initiatorKey: isInitiator ? publicKey : key, responderKey: isInitiator ? key : publicKey,
			initiatorNonce: isInitiator ? nonce : peerNonce, responderNonce: isInitiator ? peerNonce : nonce)
		let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("mousey link key v1".utf8), outputByteCount: 32)
		derivedKey = material.withUnsafeBytes { Data($0) }
		phase = .comparing(code: Self.code(transcript), peerName: Self.displayName(peerName))
		return true
	}

	/// The other side chooses its own name, and the screen asking a person to trust it shows that name. So it cannot
	/// carry line breaks, invisible characters, or text-direction tricks, and it cannot be long enough to push the code away.
	public static func displayName(_ raw: String) -> String {
		var visible = String.UnicodeScalarView()
		var marks = 0
		var numbers = 0
		for scalar in raw.unicodeScalars {
			if scalar.properties.isWhitespace {
				visible.append(" ")
				marks = 0
				continue
			}
			switch scalar.properties.generalCategory {
			case .control, .format, .surrogate, .privateUse, .unassigned:
				continue
			case .nonspacingMark, .enclosingMark, .spacingMark:
				// Real scripts stack two or three on one letter. A pile of them is text drawn over the code.
				marks += 1
				if marks <= 3 { visible.append(scalar) }
			case .decimalNumber, .letterNumber, .otherNumber:
				// The name sits beside the code, so it must not be able to spell one for a person comparing digits.
				marks = 0
				numbers += 1
				if numbers <= 2 { visible.append(scalar) }
			default:
				marks = 0
				visible.append(scalar)
			}
		}
		let words = String(visible).split(separator: " ").joined(separator: " ")
		let short = words.count > 40 ? String(words.prefix(40)) + "…" : words
		return short.isEmpty ? "Unnamed Mac" : short
	}

	private static func commitment(_ key: Data, _ nonce: Data) -> Data {
		Data(SHA256.hash(data: Data("mousey commitment v1".utf8) + key + nonce))
	}

	private static func transcript(initiatorID: String, responderID: String, initiatorName: String, responderName: String, initiatorKey: Data, responderKey: Data, initiatorNonce: Data, responderNonce: Data) -> Data {
		var out = Data("mousey transcript v1".utf8)
		for part in [Data(initiatorID.utf8), Data(responderID.utf8), Data(initiatorName.utf8), Data(responderName.utf8), initiatorKey, responderKey, initiatorNonce, responderNonce] {
			var length = UInt32(part.count).littleEndian
			out.append(Data(bytes: &length, count: 4))
			out.append(part)
		}
		return Data(SHA256.hash(data: out))
	}

	private static func code(_ transcript: Data) -> String {
		let digest = SHA256.hash(data: Data("mousey code v1".utf8) + transcript)
		let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
		return String(format: "%06llu", value)
	}
}
