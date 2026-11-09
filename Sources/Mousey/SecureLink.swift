import Foundation
import MouseyPair
import Network

/// Datagrams between paired Macs, encrypted by the system's DTLS with the key from pairing. Whoever completes the
/// handshake holds the key, so it is the paired Mac, and no other check is needed.
enum SecureLink {
	static let port: NWEndpoint.Port = 47800
	static let serviceType = "_mousey._udp"
	static let pairingServiceType = "_mousey-pair._tcp"
	static let pairingPort: NWEndpoint.Port = 47801
	/// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256.
	static let linkCipherSuite: UInt16 = 0xCCAC

	/// The paired Mac, by the name it advertises. The system resolves this for each new connection, so a changed address needs nothing.
	static func endpoint(peerID: String) -> NWEndpoint {
		.service(name: peerID, type: serviceType, domain: "local.", interface: nil)
	}

	static let policyDenied: Int32 = -65570

	/// ECDHE, so a recording stays unreadable even if the key is someone's later. The system also accepts plain-PSK
	/// suites when the other side asks for them (measured), so offering this suite is not enough and each end checks.
	static func isForwardSecret(_ connection: NWConnection) -> Bool { negotiatedSuite(connection) == linkCipherSuite }

	static func negotiatedSuite(_ connection: NWConnection) -> UInt16? {
		guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
		return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
	}

	/// `.interactiveVoice` asks Wi-Fi for its fastest queue, which only works when nothing tunnels these packets.
	static func parameters(key: Data, loopback: Bool) -> NWParameters {
		let tls = NWProtocolTLS.Options()
		func dispatchData(_ d: Data) -> __DispatchData { d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData }
		sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatchData(key), dispatchData(Data("mousey".utf8)))
		sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: linkCipherSuite)!)
		let parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
		parameters.serviceClass = .interactiveVoice
		if loopback { parameters.requiredInterfaceType = .loopback }
		return parameters
	}
}

/// Packets handed from the system's queue to a thread that keeps its own real-time priority.
final class Mailbox<Item> {
	private let lock = NSLock()
	private let signal = DispatchSemaphore(value: 0)
	private var items: [Item] = []

	func put(_ item: Item) {
		lock.lock()
		items.append(item)
		lock.unlock()
		signal.signal()
	}

	/// Everything waiting, after up to `timeoutMillis` for the first one.
	func take(timeoutMillis: Int) -> [Item] {
		_ = signal.wait(timeout: .now() + .milliseconds(timeoutMillis))
		lock.lock()
		defer { lock.unlock() }
		let out = items
		items.removeAll(keepingCapacity: true)
		return out
	}
}

/// The keyboard Mac's end. Replaced, not repaired: a new one means a new port, which the other side sees as a new peer.
final class LinkClient {
	private let connection: NWConnection
	private let queue = DispatchQueue(label: "mousey-link-client", qos: .userInteractive)

	private let deliver: (@escaping () -> Void) -> Void
	private let lock = NSLock()
	private var cancelled = false

	/// Callbacks reach the owner through `deliver`, on the owner's thread. None runs after `cancel()`, even one already
	/// on its way, because an owner that replaced this link must not hear from it.
	init(endpoint: NWEndpoint, key: Data, loopback: Bool, deliver: @escaping (@escaping () -> Void) -> Void, onPacket: @escaping (Data) -> Void, onState: @escaping (NWConnection.State) -> Void) {
		self.deliver = deliver
		connection = NWConnection(to: endpoint, using: SecureLink.parameters(key: key, loopback: loopback))
		connection.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			if case .ready = state, !SecureLink.isForwardSecret(connection) {
				Log.write("link refused: the other side settled on suite \(SecureLink.negotiatedSuite(connection).map { String($0, radix: 16) } ?? "unknown")")
				connection.cancel()
				return
			}
			hand { onState(state) }
		}
		connection.start(queue: queue)
		receive(onPacket)
	}

	private func hand(_ work: @escaping () -> Void) {
		deliver { [weak self] in
			guard let self, !isCancelled else { return }
			work()
		}
	}

	private var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}

	private func receive(_ onPacket: @escaping (Data) -> Void) {
		connection.receiveMessage { [weak self] data, _, _, error in
			guard let self else { return }
			if let data { hand { onPacket(data) } }
			if error == nil { receive(onPacket) }
		}
	}

	func send(_ data: Data) { connection.send(content: data, completion: .idempotent) }

	/// The suite the handshake settled on, once it is ready. For the self-test.
	var negotiatedSuite: UInt16? { SecureLink.negotiatedSuite(connection) }
	func cancel() {
		lock.lock()
		cancelled = true
		lock.unlock()
		connection.cancel()
	}
}

/// The controlled Mac's end. The newest connection to prove itself is the peer, because a restarted peer arrives from a
/// new port and the old session is dead.
final class LinkListener {
	struct Packet {
		let bytes: Data
		let from: NWConnection
	}

	private let listener: NWListener
	private let queue = DispatchQueue(label: "mousey-link-listener", qos: .userInteractive)
	private let onPacket: (Packet) -> Void
	private var active: NWConnection?
	/// Handshakes not yet proven. Anyone can start one, so these are capped and the oldest goes first. A flood can still delay a new link, and the keyboard Mac retries every 3 seconds. A link that is already up is not affected.
	private var pending: [NWConnection] = []
	private static let maxPending = 16
	private let ready = DispatchSemaphore(value: 0)

	init?(key: Data, port: NWEndpoint.Port, serviceName: String?, loopback: Bool, onState: @escaping (NWListener.State) -> Void = { _ in }, onPacket: @escaping (Packet) -> Void) {
		let parameters = SecureLink.parameters(key: key, loopback: loopback)
		if loopback { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port) }
		guard let made = try? (loopback ? NWListener(using: parameters) : NWListener(using: parameters, on: port)) else { return nil }
		listener = made
		self.onPacket = onPacket
		if let serviceName { listener.service = NWListener.Service(name: serviceName, type: SecureLink.serviceType) }
		listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
		listener.stateUpdateHandler = { [ready] state in
			if case .ready = state { ready.signal() }
			if case .failed = state { ready.signal() }
			onState(state)
		}
		listener.start(queue: queue)
	}

	/// For tests, which need the port the system chose.
	func waitForPort(timeoutMillis: Int = 2000) -> UInt16? {
		_ = ready.wait(timeout: .now() + .milliseconds(timeoutMillis))
		return listener.port?.rawValue
	}

	private func accept(_ connection: NWConnection) {
		if pending.count >= Self.maxPending { pending.removeFirst().cancel() }
		pending.append(connection)
		connection.start(queue: queue)
		receive(connection)
		queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
			guard let self, let connection, active !== connection else { return }
			connection.cancel()
			pending.removeAll { $0 === connection }
		}
	}

	private func receive(_ connection: NWConnection) {
		connection.receiveMessage { [weak self] data, _, _, error in
			guard let self else { return }
			if let data {
				if active !== connection {
					guard SecureLink.isForwardSecret(connection) else {
						connection.cancel()
						pending.removeAll { $0 === connection }
						return
					}
					active?.cancel()
					active = connection
					pending.removeAll { $0 === connection }
				}
				onPacket(Packet(bytes: data, from: connection))
			}
			if error == nil { receive(connection) }
		}
	}

	func stop() {
		listener.cancel()
		queue.async { [self] in
			active?.cancel()
			active = nil
			pending.forEach { $0.cancel() }
			pending = []
		}
	}
}

func linkEndpoint(address: String) -> NWEndpoint {
	.hostPort(host: NWEndpoint.Host(address.trimmingCharacters(in: .whitespaces)), port: SecureLink.port)
}
