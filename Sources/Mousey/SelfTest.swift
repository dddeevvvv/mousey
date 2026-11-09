#if DEBUG
import CoreGraphics
import Foundation
import AppKit
import MouseyClip
import MouseyCore
import MouseyPair
import Network

/// `--selftest [recording]`. No windows, no taps, no posting, loopback sockets only.
func runSelfTest(recording path: String) -> Int32 {
	var t = SelfTest()
	guard let log = loadRecording(path) else {
		print("FAIL: cannot read or decode \(path)")
		return 1
	}
	let blobs = log.steps.flatMap { step in step.blobs.map { (step: step.name, blob: $0) } }
	print("recording \(path): \(blobs.count) blobs in \(log.steps.count) steps")
	t.classification(blobs.map { $0.blob })
	t.replay(blobs.map { $0.blob })
	t.sockets()
	t.pairing()
	t.clipboard()
	t.updateCheck()
	t.shellScript()
	t.endToEnd(log)
	print(t.failed == 0 ? "selftest ok: \(t.passed) checks" : "selftest failed: \(t.failed) of \(t.passed + t.failed) checks")
	return t.failed == 0 ? 0 : 1
}

/// A real trackpad session as raw event bytes, because gestures cannot be built through public API.
struct TrackpadRecording: Decodable {
	struct Display: Decodable { var x, y, w, h: Double }
	struct System: Decodable { var displays: [Display] }
	struct Clocks: Decodable { var timebaseNumer, timebaseDenom: UInt32 }
	struct Step: Decodable {
		var name: String
		var blobs: [Blob]
	}
	var system: System
	var clocks: Clocks
	var steps: [Step]
}

struct Blob: Decodable {
	var type: UInt32
	var data: Data
}

func loadRecording(_ path: String) -> TrackpadRecording? {
	guard let data = FileManager.default.contents(atPath: path) else { return nil }
	return try? JSONDecoder().decode(TrackpadRecording.self, from: data)
}

func rebuild(_ bytes: Data) -> CGEvent? { CGEvent(withDataAllocator: nil, data: bytes as CFData) }

/// Marks a test event through the wire. `eventSourceUserData` is not serialized by `CGEvent.data`, and 41, 43, 44
/// and 102 are re-stamped on rebuild (measured). 146 survives for every recorded type and nothing here reads it.
let tagField = CGEventField(rawValue: 146)!

func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

/// A peer with the right key that asks for a suite without forward secrecy. The system lets it, which is what the app must refuse.
func weakSuite(key: Data, identity: String) -> NWProtocolTLS.Options {
	let tls = NWProtocolTLS.Options()
	func dispatchData(_ d: Data) -> __DispatchData { d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData }
	sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatchData(key), dispatchData(Data(identity.utf8)))
	sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0xCCA9)!)
	return tls
}

struct SelfTest {
	var passed = 0
	var failed = 0

	mutating func check(_ ok: Bool, _ what: String) {
		if ok { passed += 1 } else { failed += 1 }
		print("\(ok ? "PASS" : "FAIL"): \(what)")
	}

	mutating func shellScript() {
		var error: NSDictionary?
		let result = NSAppleScript(source: "do shell script \"echo ok\"")?.executeAndReturnError(&error)
		check(result?.stringValue == "ok" && error == nil, "AppleScript's do shell script runs, the path the Smooth Wi-Fi password prompt uses: \(error?.description ?? "ok")")
	}

	mutating func updateCheck() {
		func asked(status: String, body: String) -> (finished: Bool, tag: String?) {
			let parameters = NWParameters.tcp
			parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
			guard let listener = try? NWListener(using: parameters) else { return (false, nil) }
			defer { listener.cancel() }
			let reply = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
			listener.newConnectionHandler = { connection in
				connection.start(queue: .global())
				connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
					connection.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
				}
			}
			var ready = false
			listener.stateUpdateHandler = { state in
				if case .ready = state { DispatchQueue.main.async { ready = true } }
			}
			listener.start(queue: .global())
			let deadline = Date().addingTimeInterval(5)
			while !ready, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
			guard ready, let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else { return (false, nil) }
			var finished = false
			var tag: String?
			UpdateCheck.latestTag(from: url) {
				tag = $0
				finished = true
			}
			while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
			return (finished, tag)
		}
		let release = asked(status: "200 OK", body: #"{"tag_name":"v9.9.9","body":"notes","assets":[]}"#)
		check(release.finished && release.tag == "v9.9.9", "the update check reads the tag of a release: \(release)")
		let missing = asked(status: "404 Not Found", body: #"{"message":"Not Found"}"#)
		check(missing.finished && missing.tag == nil, "a repository with no release announces nothing: \(missing)")
		let garbage = asked(status: "200 OK", body: "not json")
		check(garbage.finished && garbage.tag == nil, "a reply that is not JSON announces nothing: \(garbage)")
		let noTag = asked(status: "200 OK", body: #"{"name":"no tag here"}"#)
		check(noTag.finished && noTag.tag == nil, "a reply with no tag announces nothing: \(noTag)")
		let wrongCode = asked(status: "500 Server Error", body: #"{"tag_name":"v9.9.9"}"#)
		check(wrongCode.finished && wrongCode.tag == nil, "a failed request announces nothing, even with a tag in it: \(wrongCode)")
	}

	// MARK: 1. Classify

	mutating func classification(_ blobs: [Blob]) {
		check(blobs.allSatisfy { ![10, 11, 12].contains($0.type) }, "the recording holds no key events")
		var counts: [String: Int] = [:]
		var wrong: [String] = []
		for b in blobs {
			guard let e = rebuild(b.data) else { wrong.append("type \(b.type) did not rebuild"); continue }
			let action = Classify.action(for: e)
			let expected = expectedAction(b.type, e)
			counts[label(action), default: 0] += 1
			if action != expected { wrong.append("type \(b.type): got \(action), expected \(expected)") }
		}
		check(wrong.isEmpty, "every recorded blob classifies as its type demands (\(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))" + (wrong.isEmpty ? "" : "\n  " + wrong.prefix(5).joined(separator: "\n  ")))
		let touches = blobs.filter { $0.type == 29 && rebuild($0.data)?.getIntegerValueField(field(110)) == 0 }.count
		check(counts["consume"] == touches && touches > 0, "subtype 0 touch events are consumed: \(touches) of them")
		let gestures = blobs.filter { [29, 30].contains($0.type) }.compactMap { b -> (Int, Int)? in
			guard let e = rebuild(b.data), case .input(.gesture(let phase, let kind)) = Classify.action(for: e) else { return nil }
			return (kind, phase)
		}
		let kinds = Set(gestures.map { $0.0 })
		check(kinds == [29 << 8 | 4, 29 << 8 | 6, 29 << 8 | 8, 29 << 8 | 32, 30 << 8 | 23], "gesture kinds are type<<8|subtype: \(kinds.sorted().map { "\($0 >> 8).\($0 & 0xFF)" })")
		check(Set(gestures.map { $0.1 }).isSuperset(of: [1, 2, 4]), "gesture phases include began, changed, ended: \(Set(gestures.map { $0.1 }).sorted())")

		let key = CGEvent(keyboardEventSource: nil, virtualKey: 0x0B, keyDown: true)!
		check(Classify.action(for: key) == .input(.keyDown(code: 11, isRepeat: false)), "key down")
		key.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
		check(Classify.action(for: key) == .input(.keyDown(code: 11, isRepeat: true)), "key autorepeat")
		check(Classify.action(for: CGEvent(keyboardEventSource: nil, virtualKey: 0x0B, keyDown: false)!) == .input(.keyUp(code: 11)), "key up")
		let masks: [UInt16: UInt64] = [59: 0x1, 62: 0x2000, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 63: 0x800000]
		for (code, mask) in masks.sorted(by: { $0.key < $1.key }) {
			check(Classify.action(for: flagsChanged(code, flags: mask | 0x100)) == .input(.modifier(code: code, isDown: true)), "modifier \(code) down")
			check(Classify.action(for: flagsChanged(code, flags: 0x100)) == .input(.modifier(code: code, isDown: false)), "modifier \(code) up")
		}
		check(Classify.action(for: flagsChanged(57, flags: 0x10000)) == .input(.other), "caps lock is other")
		for raw in [UInt32(0), 0xFFFF_FFFE, 0xFFFF_FFFF] {
			check(Classify.action(for: retyped(key, raw)) == .pass, "type \(raw) passes")
		}
		check(Classify.action(for: retyped(key, 14)) == .input(.other), "system defined is other")
		let motion = blobs.first { $0.type == 5 }!
		check(Classify.eventClass(for: motion.data) == .other, "eventClass: motion rebuilds as other")
		check(Classify.eventClass(for: Data([1, 2, 3])) == nil, "eventClass: garbage is nil")
		let touch = blobs.first { $0.type == 29 && rebuild($0.data)?.getIntegerValueField(field(110)) == 0 }!
		check(Classify.eventClass(for: touch.data) == nil, "eventClass: a touch event is nil")
	}

	// MARK: 2. Replay

	mutating func replay(_ blobs: [Blob]) {
		let capture = Capture()
		let original = Replay.post
		Replay.post = { capture.events.append($0) }
		defer { Replay.post = original }
		let at = CGPoint(x: 123, y: 456)
		let oneSecondTicks = UInt64(1_000_000_000) * UInt64(timebase().denom) / UInt64(timebase().numer)

		var seen = Set<UInt32>()
		for b in blobs where !seen.contains(b.type) {
			seen.insert(b.type)
			guard let before = rebuild(b.data) else { continue }
			capture.events = []
			Replay.perform(.post(bytes: b.data, at: at))
			guard let after = capture.events.first, capture.events.count == 1 else { check(false, "type \(b.type): posted \(capture.events.count) events"); continue }
			check(after.type.rawValue == b.type && after.location == at, "type \(b.type): posted once at the patched location \(after.location)")
			let changed = (0..<256).filter { f in
				![58, 169].contains(f) && before.getIntegerValueField(field(UInt32(f))) != after.getIntegerValueField(field(UInt32(f)))
			}
			check(changed.isEmpty, "type \(b.type): every field but the timestamps is preserved" + (changed.isEmpty ? "" : ", changed \(changed)"))
			let gesture = [29, 30].contains(b.type)
			let now = gesture ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : mach_absolute_time()
			let window = gesture ? UInt64(1_000_000_000) : oneSecondTicks
			check(after.timestamp <= now && now - after.timestamp < window, "type \(b.type): timestamp is current in \(gesture ? "CLOCK_UPTIME_RAW nanoseconds" : "mach ticks") (was \(before.timestamp), now \(after.timestamp))")
			let ticks = UInt64(bitPattern: after.getIntegerValueField(field(169)))
			check(ticks <= mach_absolute_time() && mach_absolute_time() - ticks < oneSecondTicks, "type \(b.type): field 169 is current in mach ticks")
		}

		capture.events = []
		Replay.perform(.releaseKey(code: 11))
		check(capture.events.first.map { $0.type == .keyUp && $0.getIntegerValueField(.keyboardEventKeycode) == 11 } == true, "releaseKey posts key up 11")
		capture.events = []
		Replay.perform(.releaseModifier(code: 56))
		check(capture.events.first.map { $0.type == .flagsChanged && $0.getIntegerValueField(.keyboardEventKeycode) == 56 && $0.flags.rawValue & 0xFFFF_0000 == 0 } == true, "releaseModifier posts flagsChanged 56 with empty flags")
		for (index, type) in [(0, CGEventType.leftMouseUp), (1, .rightMouseUp), (2, .otherMouseUp)] {
			capture.events = []
			Replay.perform(.releaseButton(index: index, at: at))
			check(capture.events.first.map { $0.type == type && $0.getIntegerValueField(.mouseEventButtonNumber) == Int64(index) && $0.location == at } == true, "releaseButton \(index) posts \(type.rawValue) at the location")
		}

		let scrolls = blobs.filter { $0.type == 22 }.compactMap { b in rebuild(b.data).map { (b, $0) } }
		if let (b, e) = scrolls.first(where: { $0.1.getIntegerValueField(.scrollWheelEventScrollPhase) == 2 }) {
			capture.events = []
			Replay.perform(.endScroll(bytes: b.data, at: at))
			let p = capture.events.first
			let zero = Replay.deltaFields.allSatisfy { p?.getDoubleValueField($0) == 0 && p?.getIntegerValueField($0) == 0 }
			check(p?.getIntegerValueField(.scrollWheelEventScrollPhase) == 4 && zero, "endScroll on a changed scroll (delta \(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))) posts phase 4 with zero deltas")
		} else { check(false, "no recorded scroll with phase 2") }
		if let (b, _) = scrolls.first(where: { ScrollPhases.isOpen(momentumPhase: Int($0.1.getIntegerValueField(.scrollWheelEventMomentumPhase))) }) {
			capture.events = []
			Replay.perform(.endScroll(bytes: b.data, at: at))
			check(capture.events.first?.getIntegerValueField(.scrollWheelEventMomentumPhase) == 3, "endScroll on a coasting scroll posts momentum phase 3")
		} else { check(false, "no recorded scroll with an open momentum phase") }
		if let b = blobs.first(where: { $0.type == 30 }), let before = rebuild(b.data) {
			capture.events = []
			Replay.perform(.endGesture(bytes: b.data, at: at))
			let p = capture.events.first
			check(p?.getIntegerValueField(field(132)) == 8 && p?.getIntegerValueField(field(134)) == 8, "endGesture on a type 30 (phase \(before.getIntegerValueField(field(132))), p134 \(before.getIntegerValueField(field(134)))) posts 8 in both phase fields")
		} else { check(false, "no recorded type 30 blob") }
	}

	// MARK: 3. The encrypted link, on loopback

	mutating func sockets() {
		let key = Data(repeating: 7, count: 32)
		let inbox = Mailbox<LinkListener.Packet>(), replies = Mailbox<Data>()
		guard let listener = LinkListener(key: key, port: .any, serviceName: nil, loopback: true, onPacket: { inbox.put($0) }), let port = listener.waitForPort() else {
			return check(false, "a loopback link listener could not be created")
		}
		defer { listener.stop() }
		let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
		func client(_ k: Data, _ out: Mailbox<Data>) -> LinkClient { LinkClient(endpoint: endpoint, key: k, loopback: true, deliver: { $0() }, onPacket: { out.put($0) }, onState: { _ in }) }
		func take<T>(_ box: Mailbox<T>, millis: Int) -> T? {
			let deadline = Date().addingTimeInterval(Double(millis) / 1000)
			while Date() < deadline { if let first = box.take(timeoutMillis: 50).first { return first } }
			return nil
		}
		let first = client(key, replies)
		first.send(Data([1, 2, 3]))
		let arrived = take(inbox, millis: 2000)
		check(arrived?.bytes == Data([1, 2, 3]), "bytes cross the encrypted link")
		arrived?.from.send(content: Data([9]), completion: .idempotent)
		check(take(replies, millis: 2000) == Data([9]), "a reply reaches the client")
		check(first.negotiatedSuite == SecureLink.linkCipherSuite, "the link negotiated the forward-secret suite: \(first.negotiatedSuite.map { String($0, radix: 16) } ?? "none")")

		let strangerOut = Mailbox<Data>()
		let stranger = client(Data(repeating: 8, count: 32), strangerOut)
		stranger.send(Data([6, 6, 6]))
		check(take(inbox, millis: 700) == nil, "a client with the wrong key delivers nothing")
		stranger.cancel()

		let weakClientParameters = NWParameters(dtls: weakSuite(key: key, identity: "mousey"), udp: NWProtocolUDP.Options())
		weakClientParameters.requiredInterfaceType = .loopback
		let weakClient = NWConnection(to: endpoint, using: weakClientParameters)
		weakClient.start(queue: .global())
		weakClient.send(content: Data([6, 6, 6]), completion: .idempotent)
		let weakDelivered = take(inbox, millis: 1000)
		let weakClientSuite = SecureLink.negotiatedSuite(weakClient)
		check(weakClientSuite != nil && weakClientSuite != SecureLink.linkCipherSuite, "a client with the right key can settle on a suite without forward secrecy: \(weakClientSuite.map { String($0, radix: 16) } ?? "none")")
		check(weakDelivered == nil, "and the controlled Mac takes nothing from it")
		weakClient.cancel()

		let weakServerParameters = NWParameters(dtls: weakSuite(key: key, identity: "mousey"), udp: NWProtocolUDP.Options())
		weakServerParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		guard let weakServer = try? NWListener(using: weakServerParameters) else { return check(false, "a loopback listener that asks for a weak suite") }
		defer { weakServer.cancel() }
		let weakServerUp = DispatchSemaphore(value: 0)
		let weakServerSuites = Mailbox<UInt16>()
		weakServer.stateUpdateHandler = { if case .ready = $0 { weakServerUp.signal() } }
		weakServer.newConnectionHandler = { connection in
			connection.stateUpdateHandler = { state in
				if case .ready = state, let suite = SecureLink.negotiatedSuite(connection) { weakServerSuites.put(suite) }
			}
			connection.start(queue: .global())
		}
		weakServer.start(queue: .global())
		_ = weakServerUp.wait(timeout: .now() + 2)
		let linkStates = Mailbox<String>()
		let refusing = LinkClient(endpoint: .hostPort(host: "127.0.0.1", port: weakServer.port ?? .any), key: key, loopback: true, deliver: { $0() }, onPacket: { _ in }, onState: { state in
			if case .ready = state { linkStates.put("ready") }
			if case .cancelled = state { linkStates.put("cancelled") }
		})
		let weakServerSuite = take(weakServerSuites, millis: 3000)
		check(weakServerSuite != nil && weakServerSuite != SecureLink.linkCipherSuite, "a listener with the right key can settle on a suite without forward secrecy: \(weakServerSuite.map { String($0, radix: 16) } ?? "none")")
		let linkState = take(linkStates, millis: 3000)
		check(linkState == "cancelled", "and the keyboard Mac drops that link instead of reporting it up: \(linkState ?? "no state")")
		refusing.cancel()

		func heldClient(_ marker: UInt8) -> (client: LinkClient, callbacks: DispatchQueue, heard: Mailbox<String>) {
			let callbacks = DispatchQueue(label: "mousey-selftest-held-\(marker)")
			callbacks.suspend()
			let heard = Mailbox<String>()
			let made = LinkClient(endpoint: endpoint, key: key, loopback: true, deliver: { callbacks.async(execute: $0) }, onPacket: { _ in heard.put("packet") }, onState: { heard.put("\($0)") })
			made.send(Data([marker]))
			return (made, callbacks, heard)
		}
		func everything(in box: Mailbox<String>, millis: Int) -> [String] {
			var all: [String] = []
			let deadline = Date().addingTimeInterval(Double(millis) / 1000)
			while Date() < deadline { all += box.take(timeoutMillis: 50) }
			return all
		}
		let kept = heldClient(81), late = heldClient(82)
		var markers = Set<Data>()
		let heldDeadline = Date().addingTimeInterval(3)
		while markers.count < 2, Date() < heldDeadline {
			for p in inbox.take(timeoutMillis: 50) where p.bytes == Data([81]) || p.bytes == Data([82]) { markers.insert(p.bytes) }
		}
		usleep(200_000)
		late.client.cancel()
		kept.callbacks.resume()
		late.callbacks.resume()
		let keptHeard = everything(in: kept.heard, millis: 600)
		let lateHeard = everything(in: late.heard, millis: 400)
		check(markers.count == 2 && keptHeard.contains("ready"), "a link's callbacks wait in its owner's queue, and arrive: \(keptHeard)")
		check(markers.count == 2 && lateHeard.isEmpty, "once the link is cancelled, none already waiting reaches the owner: \(lateHeard)")
		kept.client.cancel()

		first.cancel()
		let restartedOut = Mailbox<Data>()
		let restarted = client(key, restartedOut)
		restarted.send(Data([4]))
		let again = take(inbox, millis: 2000)
		check(again?.bytes == Data([4]), "a restarted client is heard on its new port")
		again?.from.send(content: Data([5]), completion: .idempotent)
		check(take(restartedOut, millis: 2000) == Data([5]), "and gets its reply")
		restarted.cancel()
		check(Wire.decodeVersionNotice(Wire.versionNotice()) == Wire.version, "a version notice round-trips")
		var other = [UInt8](Wire.encode(Frame(session: 1, seq: 1, sentNanos: 1, isRemote: false, x: 0, y: 0, motionSeq: 0, motion: nil, firstEventID: 0, events: [], repeats: [])))
		other[2] &+= 1
		check(Wire.decodeFrame(Data(other)) == nil && Wire.isFrameOfOtherVersion(Data(other)), "a frame from another version is recognized, not decoded")
		check(!Wire.isFrameOfOtherVersion(Wire.versionNotice()), "a notice is not mistaken for a frame")
	}

	// MARK: 3b. Pairing over a real connection, on loopback

	mutating func pairing() {
		final class Side {
			var phases: [Pairing.Phase] = []
			var disconnected = false
			var channel: PairingChannel!
			var last: Pairing.Phase? { phases.last }
		}
		func spin(until done: () -> Bool) {
			let deadline = Date().addingTimeInterval(3)
			while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
		}
		func link(codeLifetime: TimeInterval = 300) -> (a: Side, b: Side, listener: PairingListener)? {
			let a = Side(), b = Side()
			a.channel = PairingChannel(role: .initiator, id: "11111111-1111-1111-1111-111111111111", name: "MacBook", codeLifetime: codeLifetime, onPhase: { a.phases.append($0) }, onDisconnect: { a.disconnected = true })
			b.channel = PairingChannel(role: .responder, id: "22222222-2222-2222-2222-222222222222", name: "Mini", codeLifetime: codeLifetime, onPhase: { b.phases.append($0) }, onDisconnect: { b.disconnected = true })
			guard let listener = PairingListener(name: "test", loopbackPort: .any, onConnection: { b.channel.attach($0) }) else { return nil }
			spin { listener.port != nil && listener.port != 0 }
			guard let port = listener.port, let nw = NWEndpoint.Port(rawValue: port) else { return nil }
			let parameters = NWParameters.tcp
			parameters.requiredInterfaceType = .loopback
			a.channel.attach(NWConnection(host: "127.0.0.1", port: nw, using: parameters))
			return (a, b, listener)
		}
		func code(_ p: Pairing.Phase?) -> String? {
			if case .comparing(let c, _) = p { return c }
			return nil
		}
		guard let good = link() else { return check(false, "a pairing listener on loopback") }
		spin { code(good.a.last) != nil && code(good.b.last) != nil }
		check(code(good.a.last) != nil && code(good.a.last) == code(good.b.last), "both Macs show the same code over a real connection: \(code(good.a.last) ?? "none")")
		good.a.channel.confirm(match: true)
		spin { !good.b.phases.isEmpty && good.b.phases.count > 1 }
		good.b.channel.confirm(match: true)
		var keys: [Data] = []
		spin {
			keys = [good.a, good.b].compactMap { if case .paired(let p) = $0.last { return p.key } else { return nil } }
			return keys.count == 2
		}
		check(keys.count == 2 && keys[0] == keys[1], "both people saying yes gives both Macs the same key")

		guard let stale = link(codeLifetime: 0.3) else { return check(false, "a second pairing listener on loopback") }
		spin { stale.a.last == .failed(.expired) && stale.b.last == .failed(.expired) }
		check(stale.a.last == .failed(.expired) && stale.b.last == .failed(.expired) && stale.a.phases.contains { code($0) != nil }, "a code nobody answers expires on both Macs, with no key")
		stale.a.channel.cancel()
		stale.b.channel.cancel()
		stale.listener.stop()
		good.a.channel.cancel()
		good.b.channel.cancel()
		good.listener.stop()

		guard let refused = link() else { return check(false, "a second pairing listener") }
		spin { code(refused.a.last) != nil && code(refused.b.last) != nil }
		refused.a.channel.confirm(match: true)
		refused.b.channel.confirm(match: false)
		spin { refused.a.last == .failed(.rejected) && refused.b.last == .failed(.rejected) }
		check(refused.a.last == .failed(.rejected) && refused.b.last == .failed(.rejected), "a no on either Mac ends pairing on both, with no key")
		refused.a.channel.cancel()
		refused.b.channel.cancel()
		refused.listener.stop()

		let victim = Side()
		victim.channel = PairingChannel(role: .responder, id: "22222222-2222-2222-2222-222222222222", name: "Mini", onPhase: { victim.phases.append($0) }, onDisconnect: { victim.disconnected = true })
		guard let listener = PairingListener(name: "test", loopbackPort: .any, onConnection: { victim.channel.attach($0) }) else { return check(false, "a third pairing listener") }
		spin { listener.port != nil && listener.port != 0 }
		let parameters = NWParameters.tcp
		parameters.requiredInterfaceType = .loopback
		let attacker = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port!)!, using: parameters)
		attacker.start(queue: .main)
		attacker.send(content: Data([0xFF, 0xFF]) + Data(repeating: 0x41, count: 100), completion: .idempotent)
		spin { attacker.state == .cancelled || victim.disconnected }
		RunLoop.main.run(until: Date().addingTimeInterval(0.1))
		check(victim.phases.isEmpty, "an oversized message from a stranger changes nothing")
		check(victim.disconnected, "and the channel reports it is free, so the next Mac can be answered")
		attacker.cancel()
		victim.channel.cancel()
		listener.stop()

		func openFiles() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
		var current: Side?
		guard let repeated = PairingListener(name: "test", loopbackPort: .any, onConnection: { c in
			let s = Side()
			s.channel = PairingChannel(role: .responder, id: "22222222-2222-2222-2222-222222222222", name: "Mini", onPhase: { _ in }, onDisconnect: { s.disconnected = true })
			current = s
			s.channel.attach(c)
		}) else { return check(false, "a fourth pairing listener") }
		spin { repeated.port != nil && repeated.port != 0 }
		let before = openFiles()
		for _ in 0..<40 {
			current = nil
			let stranger = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: repeated.port!)!, using: parameters.copy())
			stranger.start(queue: .main)
			spin { current != nil }
			stranger.cancel()
			spin { current?.disconnected == true }
		}
		RunLoop.main.run(until: Date().addingTimeInterval(0.3))
		let after = openFiles()
		check(after <= before + 4, "40 strangers leave no open files behind (\(before) before, \(after) after)")
		repeated.stop()
	}

	// MARK: 3c. Clipboard, on loopback and on private pasteboards, never the person's real one

	mutating func clipboard() {
		func spin(until done: () -> Bool) {
			let deadline = Date().addingTimeInterval(4)
			while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
		}
		let key = Data(repeating: 3, count: 32)
		let left = NSPasteboard(name: NSPasteboard.Name("mousey-selftest-left-\(getpid())")), right = NSPasteboard(name: NSPasteboard.Name("mousey-selftest-right-\(getpid())"))
		defer {
			left.releaseGlobally()
			right.releaseGlobally()
		}
		left.clearContents()
		right.clearContents()
		left.setString("copied before sharing started", forType: .string)
		var rightUp = false, leftUp = false
		let listening = ClipboardSync(linkKey: key, peer: .loopbackListen(port: nil), board: right, onConnected: { rightUp = $0 })
		defer { listening.stop() }
		spin { (listening.localPort ?? 0) != 0 }
		guard let port = listening.localPort, port != 0 else { return check(false, "a clipboard listener on loopback") }
		let connecting = ClipboardSync(linkKey: key, peer: .loopbackConnect(port: port), board: left, onConnected: { leftUp = $0 })
		defer { connecting.stop() }
		spin { rightUp && leftUp }
		check(rightUp && leftUp, "the clipboard connection comes up over TLS with the shared key")

		listening.arriving()
		connecting.leaving()
		RunLoop.main.run(until: Date().addingTimeInterval(0.3))
		check(right.string(forType: .string) == nil, "what was on the clipboard before sharing started does not travel")

		left.clearContents()
		left.setString("hello from the keyboard Mac", forType: .string)
		listening.arriving()
		connecting.leaving()
		spin { right.string(forType: .string) != nil }
		check(right.string(forType: .string) == "hello from the keyboard Mac", "copied text arrives as input crosses")

		let countAfter = left.changeCount
		connecting.arriving()
		listening.leaving()
		RunLoop.main.run(until: Date().addingTimeInterval(0.3))
		check(left.changeCount == countAfter, "a received item is not sent back")

		left.clearContents()
		left.setString("planted with no crossing", forType: .string)
		right.clearContents()
		right.setString("mine", forType: .string)
		connecting.leaving()
		RunLoop.main.run(until: Date().addingTimeInterval(0.3))
		check(right.string(forType: .string) == "mine", "an item with no crossing on the receiving Mac is held back")
		RunLoop.main.run(until: Date().addingTimeInterval(ClipSession.earlyWindow + 0.2))

		right.clearContents()
		right.setString("from the other Mac", forType: .string)
		connecting.arriving()
		listening.leaving()
		spin { left.string(forType: .string) == "from the other Mac" }
		check(left.string(forType: .string) == "from the other Mac", "it works in the other direction too")

		let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		for x in stride(from: 0, to: 600, by: 3) { image.setColor(NSColor(calibratedRed: CGFloat(x % 256) / 255, green: 0.2, blue: 0.7, alpha: 1), atX: x, y: x) }
		let png = image.representation(using: .png, properties: [:])!
		left.clearContents()
		left.setData(png, forType: .png)
		listening.arriving()
		connecting.leaving()
		spin { right.data(forType: .png) != nil }
		check(right.data(forType: .png) == png, "a PNG arrives byte for byte, \(png.count) bytes")

		left.clearContents()
		left.setData(image.representation(using: .tiff, properties: [:])!, forType: .tiff)
		right.clearContents()
		listening.arriving()
		connecting.leaving()
		spin { right.data(forType: .png) != nil }
		check(right.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 600, "a TIFF arrives as a PNG of the same image")

		let large = Data(repeating: 65, count: ClipItem.maxTextBytes)
		left.clearContents()
		left.setString(String(decoding: large, as: UTF8.self), forType: .string)
		right.clearContents()
		listening.arriving()
		connecting.leaving()
		spin { right.string(forType: .string)?.utf8.count == large.count }
		check(right.string(forType: .string)?.utf8.count == large.count, "text at the 1 MB limit arrives whole")

		right.clearContents()
		left.clearContents()
		left.setString(String(decoding: large + Data([65]), as: UTF8.self), forType: .string)
		listening.arriving()
		connecting.leaving()
		RunLoop.main.run(until: Date().addingTimeInterval(0.4))
		check(right.string(forType: .string) == nil, "text over the limit stays home")
		RunLoop.main.run(until: Date().addingTimeInterval(0.05))

		for (name, type) in [("a secret", "org.nspasteboard.ConcealedType"), ("a transient item", "org.nspasteboard.TransientType")] {
			left.clearContents()
			left.declareTypes([.string, NSPasteboard.PasteboardType(type)], owner: nil)
			left.setString("s3cret", forType: .string)
			check(Clipboard.read(left) == nil, "\(name) marked by a password manager is never read")
		}
		left.clearContents()
		left.declareTypes([.fileURL, .string], owner: nil)
		left.setString("file:///etc/hosts", forType: .fileURL)
		left.setString("hosts", forType: .string)
		check(Clipboard.read(left) == nil, "copied files stay home")

		left.clearContents()
		left.setString("safe\u{1B}[201~rm -rf ~", forType: .string)
		check(Clipboard.read(left) == nil, "text with a terminal escape in it stays home")
		left.clearContents()
		left.setString("javascript:alert(1)", forType: .URL)
		check(Clipboard.read(left) == nil, "a link that is not a web link stays home")

		left.clearContents()
		left.setString("https://example.com/", forType: .URL)
		guard let link = Clipboard.read(left) else { return check(false, "a copied link is read") }
		check(link.kind == .url, "a copied link is read as a link")
		right.clearContents()
		_ = Clipboard.write(link, to: right)
		check(right.string(forType: .URL) == "https://example.com/" && right.string(forType: .string) == "https://example.com/", "a received link pastes as a link and as text")

		var strangerUp = false
		let strangerBoard = NSPasteboard(name: NSPasteboard.Name("mousey-selftest-stranger-\(getpid())"))
		defer { strangerBoard.releaseGlobally() }
		let stranger = ClipboardSync(linkKey: Data(repeating: 4, count: 32), peer: .loopbackConnect(port: port), board: strangerBoard, onConnected: { strangerUp = $0 })
		defer { stranger.stop() }
		spin { strangerUp }
		check(!strangerUp, "a client with the wrong key never connects")
		check(rightUp && leftUp, "and the real connection stays up")

		let weakParameters = NWParameters(tls: weakSuite(key: clipboardKey(fromLinkKey: key), identity: "mousey-clipboard"), tcp: NWProtocolTCP.Options())
		weakParameters.requiredInterfaceType = .loopback
		let weakClient = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: weakParameters)
		var weakClientSuite: UInt16?
		weakClient.stateUpdateHandler = { state in
			if case .ready = state { weakClientSuite = SecureLink.negotiatedSuite(weakClient) }
		}
		weakClient.start(queue: .main)
		spin { weakClientSuite != nil }
		RunLoop.main.run(until: Date().addingTimeInterval(0.5))
		check(weakClientSuite != nil && weakClientSuite != SecureLink.linkCipherSuite, "a clipboard client with the right key can settle on a suite without forward secrecy: \(weakClientSuite.map { String($0, radix: 16) } ?? "none")")
		check(rightUp && leftUp, "and the controlled Mac does not take it as the new peer")
		weakClient.cancel()

		let silentParameters = NWParameters.tcp
		silentParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		guard let silent = try? NWListener(using: silentParameters) else { return check(false, "a silent listener on loopback") }
		var silentUp = false
		var silentConnections: [NWConnection] = []
		silent.stateUpdateHandler = { if case .ready = $0 { silentUp = true } }
		silent.newConnectionHandler = { connection in
			silentConnections.append(connection)
			connection.start(queue: .main)
		}
		silent.start(queue: .main)
		spin { silentUp }
		let waiting = ClipboardSync(linkKey: key, peer: .loopbackConnect(port: silent.port?.rawValue ?? 1), board: strangerBoard)
		let silentDeadline = Date().addingTimeInterval(12)
		while silentConnections.count < 2, Date() < silentDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
		check(silentConnections.count >= 2, "a peer that never finishes the handshake is dropped and tried again: \(silentConnections.count) connections")
		waiting.stop()
		silent.cancel()
		silentConnections.forEach { $0.cancel() }

		// The order people really do this in: the keyboard Mac first, and the other Mac a little later.
		var earlyUp = false, lateUp = false
		let pick = ClipboardSync(linkKey: key, peer: .loopbackListen(port: nil), board: strangerBoard)
		spin { (pick.localPort ?? 0) != 0 }
		let freePort = pick.localPort ?? 0
		pick.stop()
		RunLoop.main.run(until: Date().addingTimeInterval(0.2))
		let keyboardFirst = ClipboardSync(linkKey: key, peer: .loopbackConnect(port: freePort), board: left, onConnected: { earlyUp = $0 })
		defer { keyboardFirst.stop() }
		RunLoop.main.run(until: Date().addingTimeInterval(1))
		let otherLater = ClipboardSync(linkKey: key, peer: .loopbackListen(port: freePort), board: right, onConnected: { lateUp = $0 })
		defer { otherLater.stop() }
		let deadline = Date().addingTimeInterval(8)
		while !(earlyUp && lateUp), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
		check(earlyUp && lateUp, "a keyboard Mac that turned sharing on first connects once the other Mac does")
	}

	// MARK: 4. End to end on loopback, with real recorded bytes through the real Classify

	mutating func endToEnd(_ log: TrackpadRecording) {
		let capture = Capture()
		let original = Replay.post
		Replay.post = { capture.events.append($0) }
		defer { Replay.post = original }
		let laptop = Displays(log.system.displays.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) })
		let targetScreen = Displays([CGRect(x: 0, y: 0, width: 2560, height: 1440)])
		guard let target = LoopbackTarget(displays: targetScreen) else { return check(false, "loopback target") }
		let answers = Mailbox<Data>()
		let link = LinkClient(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target.port)!), key: LoopbackTarget.key, loopback: true, deliver: { $0() }, onPacket: { answers.put($0) }, onState: { _ in })
		defer { link.cancel() }
		target.start()
		defer { target.stop() }
		var core = ControllerCore(session: 0xC0FF_EE01, edge: .right, displays: laptop, now: monotonicNow())
		var sizes: [Int] = []
		var roundTrips: [UInt64] = []
		var nextTick: Tick = 0
		func drive(_ input: ControllerInput) -> ControllerOutput {
			let out = core.handle(input, now: monotonicNow())
			for effect in out.effects {
				if case .send(let frame) = effect {
					let bytes = Wire.encode(frame)
					sizes.append(bytes.count)
					link.send(bytes)
				}
				if case .roundTrip(let nanos) = effect { roundTrips.append(nanos) }
			}
			nextTick = out.nextTick
			return out
		}
		func pump(_ nanos: Tick) {
			let deadline = monotonicNow() + nanos
			while monotonicNow() < deadline {
				for data in answers.take(timeoutMillis: 0) { if let ack = Wire.decodeAck(data) { _ = drive(.ack(ack)) } }
				if monotonicNow() >= nextTick { _ = drive(.tick) }
				usleep(200)
			}
		}
		_ = drive(.tick)
		pump(50_000_000)
		check(core.status.targetOnline && core.status.targetCanInject, "the loopback target answers the first frame")

		let edge = CGPoint(x: laptop.frames[0].maxX - 0.5, y: laptop.frames[0].midY)
		var parked: CGPoint?
		for _ in 0..<4 where parked == nil {
			parked = drive(.watchMotion(location: edge, dx: 12, dy: 0, buttonsHeld: false)).effects.compactMap { if case .beginCapture(let p) = $0 { return p } else { return nil } }.first
			pump(45_000_000)
		}
		check(parked == CGPoint(x: laptop.frames[0].midX, y: laptop.frames[0].midY) && core.status.isRemote, "pushing through the right edge crosses and parks at the display center")
		let motionBlob = log.steps.flatMap { $0.blobs }.first { $0.type == 5 }!.data
		_ = drive(.grabbedMotion(dx: 0, dy: 0, bytes: motionBlob))
		// Away from every edge, so the recorded streams cannot push back out.
		_ = drive(.grabbedMotion(dx: 1280, dy: 720, bytes: motionBlob))
		pump(20_000_000)

		let tb = log.clocks
		func nanos(_ e: CGEvent) -> UInt64 {
			Classify.clock(for: e) == .uptimeRawNanos ? e.timestamp : e.timestamp * UInt64(tb.timebaseNumer) / UInt64(tb.timebaseDenom)
		}
		var expected: [(tag: Int64, at: CGPoint)] = []
		var fed = (motion: 2, input: 0, consumed: 0, passed: 0)
		var tag: Int64 = 0
		for step in log.steps {
			var previous: UInt64?
			for b in step.blobs {
				guard let e = rebuild(b.data) else { continue }
				let at = nanos(e)
				if let p = previous, at > p { pump(min((at - p) / 10, 2_000_000)) }
				previous = at
				switch Classify.action(for: e) {
				case .consume: fed.consumed += 1
				case .pass: fed.passed += 1
				case .motion(let dx, let dy):
					fed.motion += 1
					_ = drive(.grabbedMotion(dx: dx, dy: dy, bytes: b.data))
				case .input(let input):
					fed.input += 1
					tag += 1
					e.setIntegerValueField(tagField, value: tag)
					let out = drive(.grabbed(input, bytes: e.data! as Data, flags: e.flags.rawValue))
					// The frame sent with a forwarded event carries the capture position that the event was stamped with.
					for case .send(let frame) in out.effects { expected.append((tag, CGPoint(x: frame.x, y: frame.y))) }
				}
			}
		}
		pump(30_000_000)
		print("fed \(fed.motion) motion and \(fed.input) input events, consumed \(fed.consumed), passed \(fed.passed); \(expected.count) forwarded with a tag")
		check(fed.input == expected.count, "every input event was forwarded")

		var returned = false
		for _ in 0..<4 where !returned {
			fed.motion += 1
			returned = !drive(.grabbedMotion(dx: -3000, dy: 0, bytes: motionBlob)).effects.compactMap { if case .endCapture(let p) = $0 { return p } else { return nil } }.isEmpty
			pump(45_000_000)
		}
		check(returned && !core.status.isRemote, "pushing through the target's far edge returns to local")
		pump(1_100_000_000)
		target.stop()

		let posted = capture.events
		let tagged = posted.filter { $0.getIntegerValueField(tagField) != 0 }.map { (tag: $0.getIntegerValueField(tagField), at: $0.location) }
		let batches = target.batches
		let releases = batches.map { $0.filter { if case .post = $0 { return false }; if case .postMotion = $0 { return false }; if case .declareUserActivity = $0 { return false }; return true } }
		// Ending a cut-off stream replays its last real event with the phase changed, so that event's tag is posted twice.
		let endStreams = releases.joined().filter { if case .endScroll = $0 { return true }; if case .endGesture = $0 { return true }; return false }.count
		let orderOK = tagged.prefix(expected.count).map { $0.tag } == expected.map { $0.tag } && tagged.count == expected.count + endStreams
		let placeOK = zip(tagged, expected).allSatisfy { $0.at == $1.at }
		let firstWrong = zip(tagged, expected).first { $0.tag != $1.tag || $0.at != $1.at }
		check(orderOK && placeOK, "all \(expected.count) forwarded events were posted once, in capture order, at their capture position (posted \(tagged.count), of which \(endStreams) end a cut-off stream)"
			+ (firstWrong.map { "\n  first mismatch: posted tag \($0.0.tag) at \($0.0.at), expected tag \($0.1.tag) at \($0.1.at)" } ?? ""))
		let motions = posted.filter { Classify.motionTypes.contains($0.type.rawValue) }
		check(!motions.isEmpty && motions.count <= fed.motion, "motion posts coalesce: \(motions.count) of \(fed.motion) fed")
		check(posted.allSatisfy { e in targetScreen.frames.contains { $0.contains(e.location) } }, "every post lies on the target's display")
		let lastRelease = releases.lastIndex { !$0.isEmpty }
		let afterFirstRelease = releases.enumerated().filter { $0.offset > (releases.firstIndex { !$0.isEmpty } ?? Int.max) && !$0.element.isEmpty }
		check(lastRelease != nil && afterFirstRelease.isEmpty, "the return released what the cut-off streams left open (\(releases.first { !$0.isEmpty }?.count ?? 0) commands), and nothing is held after that")
		check(target.status.droppedEvents == 0 && target.status.controlled == false, "the target dropped nothing and is no longer controlled")
		let largest = sizes.max() ?? 0
		check(largest <= 1252, "largest frame \(largest) bytes of \(sizes.count) sent fits the 1252-byte datagram limit")
		let sorted = roundTrips.sorted()
		if sorted.isEmpty {
			check(false, "no round-trip samples")
		} else {
			let p = { (q: Double) in Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) / 1e6 }
			print(String(format: "loopback round trip: median %.3f ms, p99 %.3f ms, max %.3f ms over %d samples", p(0.5), p(0.99), p(1), sorted.count))
			check(p(0.99) < 50, "loopback round-trip p99 under 50 ms")
		}
	}

	private func expectedAction(_ type: UInt32, _ e: CGEvent) -> Action {
		switch type {
		case 5, 6, 7, 27: return .motion(dx: e.getDoubleValueField(.mouseEventDeltaX), dy: e.getDoubleValueField(.mouseEventDeltaY))
		case 1: return .input(.button(index: Int(e.getIntegerValueField(.mouseEventButtonNumber)), isDown: true))
		case 2: return .input(.button(index: Int(e.getIntegerValueField(.mouseEventButtonNumber)), isDown: false))
		case 22: return .input(.scroll(phase: Int(e.getIntegerValueField(field(99))), momentumPhase: Int(e.getIntegerValueField(field(123)))))
		case 29 where e.getIntegerValueField(field(110)) == 0: return .consume
		case 29, 30: return .input(.gesture(phase: Int(e.getIntegerValueField(field(132))), kind: Int(type) << 8 | Int(e.getIntegerValueField(field(110)))))
		default: return .input(.other)
		}
	}

	private func label(_ a: Action) -> String {
		switch a {
		case .motion: return "motion"
		case .consume: return "consume"
		case .pass: return "pass"
		case .input(.button): return "button"
		case .input(.scroll): return "scroll"
		case .input(.gesture): return "gesture"
		case .input: return "other"
		}
	}
}

/// A real `TargetCore` behind a loopback link on its own thread, replaying through `Replay` (whose poster the
/// caller replaces) and answering each accepted frame with one ack, the way `TargetEngine` does.
final class LoopbackTarget {
	static let key = Data(repeating: 0x4B, count: 32)
	private let listener: LinkListener
	private let mailbox = Mailbox<LinkListener.Packet>()
	private var core: TargetCore
	private var thread: Thread?
	private let done = DispatchSemaphore(value: 0)
	let port: UInt16
	/// The commands performed per loop pass. Read after `stop()`.
	private(set) var batches: [[TargetCommand]] = []

	init?(displays: Displays) {
		let mailbox = mailbox
		guard let made = LinkListener(key: Self.key, port: .any, serviceName: nil, loopback: true, onPacket: { mailbox.put($0) }), let port = made.waitForPort() else { return nil }
		listener = made
		self.port = port
		core = TargetCore(displays: displays, classify: Classify.eventClass(for:))
	}

	var status: TargetStatus { core.status }

	func start() {
		let t = Thread { [self] in run() }
		t.name = "mousey-loopback-target"
		thread = t
		t.start()
	}

	func stop() {
		guard let thread, !thread.isCancelled else { return }
		thread.cancel()
		_ = done.wait(timeout: .now() + .milliseconds(400))
		listener.stop()
	}

	private func run() {
		while !Thread.current.isCancelled {
			var commands: [TargetCommand] = []
			var reply: (ack: Ack, to: LinkListener.Packet)?
			for p in mailbox.take(timeoutMillis: 50) {
				if let frame = Wire.decodeFrame(p.bytes) {
					let (c, ack) = core.receive(frame, canInject: true, now: monotonicNow())
					commands += c
					reply = (ack, p)
				}
			}
			commands += core.tick(now: monotonicNow())
			let batch = coalesce(commands)
			for command in batch { Replay.perform(command) }
			if !batch.isEmpty { batches.append(batch) }
			if let reply { reply.to.from.send(content: Wire.encode(reply.ack), completion: .idempotent) }
		}
		done.signal()
	}
}

final class Capture {
	var events: [CGEvent] = []
}

func flagsChanged(_ code: UInt16, flags: UInt64) -> CGEvent {
	let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
	e.type = .flagsChanged
	e.flags = CGEventFlags(rawValue: flags)
	return e
}

func retyped(_ e: CGEvent, _ raw: UInt32) -> CGEvent {
	let copy = e.copy()!
	copy.type = unsafeBitCast(raw, to: CGEventType.self)
	return copy
}
#endif
