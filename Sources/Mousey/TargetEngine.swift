import CoreGraphics
import Foundation
import MouseyCore
import Network

struct TargetReport: Equatable {
	var core: TargetStatus
	var canInject: Bool
	/// False when the port could not be opened.
	var bound: Bool
	/// macOS is refusing this app the local network.
	var networkDenied: Bool
	/// Set when a frame arrived from a different version of the app.
	var versionMismatch: Bool
}

/// One thread owns `TargetCore`. It sends nothing except replies to frames that arrived over the encrypted link.
final class TargetEngine {
	private let onReport: (TargetReport) -> Void
	private let key: Data
	private let serviceName: String
	private let mailbox = Mailbox<LinkListener.Packet>()
	private let done = DispatchSemaphore(value: 0)
	private var thread: Thread?
	private var core: TargetCore
	private var displays: Displays
	private var listener: LinkListener?
	private var versionMismatch = false
	private var canInject = false
	private var startupDone = false
	private var lastPermissionCheck: Tick = 0
	private var lastOpenAttempt: Tick = 0
	private var lastReport: TargetReport?
	private var lastReportAt: Tick = 0
	private var rejectedLogged = 0
	private var wasControlled = false
	/// Slow system calls, from their own queue. `CGPreflightPostEventAccess` alone takes 6 to 9 ms (measured), far past
	/// this thread's 2 ms constraint, and packets would wait behind it once a second.
	private let checksLock = NSLock()
	private var checked: (allowed: Bool, displays: Displays)?
	private var checksTimer: DispatchSourceTimer?
	private var listenerFailed = false
	private var networkDenied = false
	private var deniedSeen = false
	/// Timing for the log, never input. The two Macs' clocks differ, so only the variation of `transit` means anything.
	private var transit: [Int64] = []
	private var work: [UInt64] = []
	private var slowestHousekeeping: UInt64 = 0

	init(key: Data, serviceName: String, onReport: @escaping (TargetReport) -> Void) {
		self.key = key
		self.serviceName = serviceName
		self.onReport = onReport
		displays = activeDisplays()
		core = TargetCore(displays: displays, classify: Classify.eventClass(for:))
		let t = Thread { [self] in run() }
		t.name = "mousey-target"
		thread = t
		t.start()
	}

	/// Returns once the loop has exited, which takes at most one receive timeout.
	func stop() {
		thread?.cancel()
		_ = done.wait(timeout: .now() + .milliseconds(400))
	}

	private func run() {
		setRealtimePolicy()
		apply(allowed: CGPreflightPostEventAccess(), displays: activeDisplays())
		let checks = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mousey-target-checks", qos: .utility))
		checks.schedule(deadline: .now() + 1, repeating: 1)
		checks.setEventHandler { [self] in
			let result = (allowed: CGPreflightPostEventAccess(), displays: activeDisplays())
			checksLock.lock()
			checked = result
			checksLock.unlock()
		}
		checks.resume()
		checksTimer = checks
		while !Thread.current.isCancelled {
			var commands: [TargetCommand] = []
			var reply: (ack: Ack, to: LinkListener.Packet)?
			let packets = mailbox.take(timeoutMillis: 200)
			let arrived: Tick? = packets.isEmpty ? nil : monotonicNow()
			for p in packets { process(p, into: &commands, reply: &reply) }
			commands += core.tick(now: monotonicNow())
			noteControl()
			for command in coalesce(commands) { Replay.perform(command) }
			if let reply { reply.to.from.send(content: Wire.encode(reply.ack), completion: .idempotent) }
			if let arrived, wasControlled { work.append(monotonicNow() - arrived) }
			let before = monotonicNow()
			housekeeping(now: before)
			if wasControlled { slowestHousekeeping = max(slowestHousekeeping, monotonicNow() - before) }
		}
		checks.cancel()
		for command in core.releaseAll() { Replay.perform(command) }
		noteControl()
		flushTiming()
		listener?.stop()
		listener = nil
		done.signal()
	}

	private func process(_ p: LinkListener.Packet, into commands: inout [TargetCommand], reply: inout (ack: Ack, to: LinkListener.Packet)?) {
		guard let frame = Wire.decodeFrame(p.bytes) else {
			if Wire.isFrameOfOtherVersion(p.bytes) {
				if !versionMismatch { Log.write("a frame arrived from a different version of the app") }
				versionMismatch = true
				p.from.send(content: Wire.versionNotice(), completion: .idempotent)
			} else if rejectedLogged < 5 {
				rejectedLogged += 1
				Log.write("undecodable frame of \(p.bytes.count) bytes from the peer")
			}
			return
		}
		versionMismatch = false
		if !core.status.controllerSeen { Log.write("first frame from the peer, can post events: \(canInject)") }
		let arrival = monotonicNow()
		if frame.isRemote { transit.append(Int64(bitPattern: arrival &- frame.sentNanos)) }
		if transit.count >= 4000 { flushTiming() }
		let (cmds, ack) = core.receive(frame, canInject: canInject, now: arrival)
		commands += cmds
		reply = (ack, p)
	}

	/// After the tick, so silence ends control too. A keyboard Mac that sleeps must not leave AWDL off here.
	private func noteControl() {
		guard core.status.controlled != wasControlled else { return }
		wasControlled = core.status.controlled
		Log.write(wasControlled ? "controlled by the peer" : "control ended by the peer")
		if wasControlled {
			AwdlLease.shared.hold()
			ClipboardSync.noteArriving()
		} else {
			AwdlLease.shared.letGo()
			ClipboardSync.noteLeaving()
			flushTiming()
		}
	}

	private func apply(allowed: Bool, displays found: Displays) {
		if allowed != canInject { Log.write("can post events: \(allowed)") }
		canInject = allowed
		if canInject && !startupDone {
			startupDone = true
			Replay.releaseEverythingAtStartup()
		}
		if found != displays {
			displays = found
			core.setDisplays(found)
		}
	}

	private func flushTiming() {
		guard let fastest = transit.min() else { return }
		let t = transit.map { UInt64($0 - fastest) }, w = work, h = slowestHousekeeping
		transit.removeAll(keepingCapacity: true)
		work.removeAll(keepingCapacity: true)
		slowestHousekeeping = 0
		DispatchQueue.global(qos: .utility).async {
			Log.write("timing over \(t.count) frames: network above the fastest frame \(latencySummary(t)), work per wake \(latencySummary(w)), slowest housekeeping \(String(format: "%.2f", Double(h) / 1e6)) ms")
		}
	}

	private func housekeeping(now: Tick) {
		if now - lastPermissionCheck >= 1_000_000_000 {
			lastPermissionCheck = now
			// Never wait on the lock here. A miss just waits for the next second.
			// Idempotent, so a helper installed or restarted during a session is picked up.
			if wasControlled { AwdlLease.shared.hold() }
			if checksLock.try() {
				let result = checked
				checked = nil
				networkDenied = deniedSeen
				if listenerFailed {
					listenerFailed = false
					listener?.stop()
					listener = nil
				}
				checksLock.unlock()
				if let result { apply(allowed: result.allowed, displays: result.displays) }
			}
		}
		if listener == nil, now - lastOpenAttempt >= 2_000_000_000 {
			lastOpenAttempt = now
			openListener()
		}
		report(now: now)
	}

	private func openListener() {
		let mailbox = mailbox
		listener = LinkListener(key: key, port: SecureLink.port, serviceName: serviceName, loopback: false, onState: { [weak self] state in
			guard let self else { return }
			checksLock.lock()
			defer { checksLock.unlock() }
			switch state {
			case .ready:
				deniedSeen = false
			case .waiting(let error):
				if case .dns(let code) = error, code == SecureLink.policyDenied { deniedSeen = true }
				Log.write("listener waiting: \(error)")
			case .failed(let error):
				Log.write("listener failed: \(error)")
				listenerFailed = true
			default:
				break
			}
		}, onPacket: { mailbox.put($0) })
		Log.write(listener == nil ? "could not open port \(SecureLink.port.rawValue)" : "listening on port \(SecureLink.port.rawValue)")
	}

	private func report(now: Tick) {
		let r = TargetReport(core: core.status, canInject: canInject, bound: listener != nil, networkDenied: networkDenied, versionMismatch: versionMismatch)
		guard r != lastReport, now - lastReportAt >= 250_000_000 else { return }
		lastReport = r
		lastReportAt = now
		DispatchQueue.main.async { [onReport] in onReport(r) }
	}
}
