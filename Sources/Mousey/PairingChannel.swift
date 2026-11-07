import Foundation
import MouseyPair
import Network

/// Carries `Pairing` messages over TCP, and advertises or finds the other side. Nothing here is trusted: the state
/// machine and the person comparing codes are what make pairing safe. Runs on the main queue.
final class PairingChannel {
	private static let maxMessage = 4096
	private var pairing: Pairing
	private var connection: NWConnection?
	private var buffer = Data()
	private let onPhase: (Pairing.Phase) -> Void
	private let onDisconnect: () -> Void
	private let onWaiting: (NWError) -> Void
	private let codeLifetime: TimeInterval
	private var expiryStarted = false

	init(role: Pairing.Role, id: String, name: String, codeLifetime: TimeInterval = 300, onPhase: @escaping (Pairing.Phase) -> Void, onDisconnect: @escaping () -> Void, onWaiting: @escaping (NWError) -> Void = { _ in }) {
		pairing = Pairing(role: role, id: id, name: name)
		self.codeLifetime = codeLifetime
		self.onPhase = onPhase
		self.onDisconnect = onDisconnect
		self.onWaiting = onWaiting
	}

	func attach(_ connection: NWConnection) {
		self.connection?.cancel()
		self.connection = connection
		connection.stateUpdateHandler = { [weak self, weak connection] state in
			guard let self, let connection, self.connection === connection else { return }
			switch state {
			case .ready:
				send(pairing.start())
				read()
			case .failed:
				cancel()
				onDisconnect()
			case .waiting(let error):
				onWaiting(error)
			default:
				break
			}
		}
		connection.start(queue: .main)
	}

	func confirm(match: Bool) {
		send(pairing.confirm(match: match))
		reportPhase()
	}

	func cancel() {
		connection?.stateUpdateHandler = nil
		connection?.cancel()
		connection = nil
	}

	/// Ends the conversation after what was already sent has gone. The last Yes or No must reach the other Mac, or it
	/// is left waiting, or holding no key while this one has it.
	func close() {
		guard let open = connection else { return }
		open.stateUpdateHandler = nil
		connection = nil
		// A connection that never became ready would never finish this send.
		guard case .ready = open.state else { return open.cancel() }
		open.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in open.cancel() })
	}

	private func read() {
		connection?.receive(minimumIncompleteLength: 1, maximumLength: Self.maxMessage) { [weak self] data, _, isComplete, error in
			guard let self else { return }
			if let data { buffer.append(data) }
			guard drain(), !isComplete, error == nil else {
				cancel()
				return onDisconnect()
			}
			if connection != nil { read() }
		}
	}

	/// False when the peer sent something no honest peer sends.
	private func drain() -> Bool {
		while buffer.count >= 2 {
			let bytes = [UInt8](buffer.prefix(2))
			let length = Int(bytes[0]) | Int(bytes[1]) << 8
			guard length <= Self.maxMessage else { return false }
			guard buffer.count >= 2 + length else { return true }
			let body = buffer.dropFirst(2).prefix(length)
			buffer = Data(buffer.dropFirst(2 + length))
			guard let message = try? JSONDecoder().decode(PairingMessage.self, from: Data(body)) else { return false }
			send(pairing.receive(message))
			reportPhase()
		}
		return true
	}

	private func reportPhase() {
		if case .comparing = pairing.phase, !expiryStarted {
			expiryStarted = true
			DispatchQueue.main.asyncAfter(deadline: .now() + codeLifetime) { [weak self] in
				guard let self, case .comparing = pairing.phase else { return }
				pairing.expire()
				onPhase(pairing.phase)
			}
		}
		onPhase(pairing.phase)
	}

	private func send(_ messages: [PairingMessage]) {
		for message in messages {
			guard let body = try? JSONEncoder().encode(message), body.count <= Self.maxMessage else { continue }
			connection?.send(content: Data([UInt8(truncatingIfNeeded: body.count), UInt8(body.count >> 8)]) + body, completion: .contentProcessed { _ in })
		}
	}
}

/// The controlled Mac's side of pairing: listens, and answers one Mac at a time.
final class PairingListener {
	private var listener: NWListener?

	init?(name: String, loopbackPort: NWEndpoint.Port? = nil, onState: @escaping (NWListener.State) -> Void = { _ in }, onConnection: @escaping (NWConnection) -> Void) {
		let parameters = NWParameters.tcp
		if let loopbackPort {
			parameters.requiredInterfaceType = .loopback
			parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: loopbackPort)
		}
		guard let made = try? (loopbackPort != nil ? NWListener(using: parameters) : NWListener(using: parameters, on: SecureLink.pairingPort)) else { return nil }
		if loopbackPort == nil { made.service = NWListener.Service(name: name, type: SecureLink.pairingServiceType) }
		made.newConnectionHandler = onConnection
		made.stateUpdateHandler = onState
		made.start(queue: .main)
		listener = made
	}

	var port: UInt16? { listener?.port?.rawValue }
	func stop() { listener?.cancel() }
}

/// The keyboard Mac's list of nearby Macs that are ready to pair.
final class PairingBrowser {
	struct Found: Identifiable, Equatable {
		let name: String
		let endpoint: NWEndpoint
		var id: String { name }
	}

	enum Trouble: Equatable { case none, localNetworkDenied, other(String) }

	private let browser = NWBrowser(for: .bonjour(type: SecureLink.pairingServiceType, domain: nil), using: NWParameters())

	init(onChange: @escaping ([Found]) -> Void, onTrouble: @escaping (Trouble) -> Void) {
		browser.browseResultsChangedHandler = { results, _ in
			onChange(results.compactMap { result in
				guard case .service(let name, _, _, _) = result.endpoint else { return nil }
				return Found(name: Pairing.displayName(name), endpoint: result.endpoint)
			}.sorted { $0.name < $1.name })
		}
		browser.stateUpdateHandler = { state in
			switch state {
			case .ready: onTrouble(.none)
			case .waiting(let error), .failed(let error):
				if case .dns(let code) = error, code == SecureLink.policyDenied { onTrouble(.localNetworkDenied) } else { onTrouble(.other("\(error)")) }
			default: break
			}
		}
		browser.start(queue: .main)
	}

	func stop() { browser.cancel() }
}
