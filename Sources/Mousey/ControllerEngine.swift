import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MouseyCore
import Network

/// Counts across sleep, so `ControllerCore`'s clock-gap check catches a missed sleep notification.
func monotonicNow() -> Tick { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

func activeDisplays() -> Displays {
	var ids = [CGDirectDisplayID](repeating: 0, count: 16)
	var count: UInt32 = 0
	CGGetActiveDisplayList(16, &ids, &count)
	return Displays(ids.prefix(Int(count)).map(CGDisplayBounds))
}

func timebase() -> mach_timebase_info {
	var t = mach_timebase_info()
	mach_timebase_info(&t)
	return t
}

/// A private call, resolved at run time, so a future macOS without it only loses the cursor hiding.
enum CGS {
	static func setCursorInBackground() -> Bool {
		typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
		typealias DefaultConnection = @convention(c) () -> Int32
		let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
		guard let set = dlsym(rtldDefault, "CGSSetConnectionProperty"), let connection = dlsym(rtldDefault, "_CGSDefaultConnection") else { return false }
		let id = unsafeBitCast(connection, to: DefaultConnection.self)()
		return unsafeBitCast(set, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
	}
}

/// Measured on this Mac: 0 of 7500 loopback packets over 1 ms, against 2 of 7500 at `userInteractive`.
func setRealtimePolicy() {
	let tb = timebase()
	func ticks(_ nanos: UInt64) -> UInt32 { UInt32(nanos * UInt64(tb.denom) / UInt64(tb.numer)) }
	var policy = thread_time_constraint_policy_data_t(period: ticks(8_000_000), computation: ticks(500_000), constraint: ticks(2_000_000), preemptible: 1)
	// THREAD_TIME_CONSTRAINT_POLICY_COUNT is not imported, so the count is written out.
	_ = withUnsafeMutablePointer(to: &policy) {
		$0.withMemoryRebound(to: integer_t.self, capacity: 4) {
			thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, 4)
		}
	}
}

struct ControllerReport: Equatable {
	var core: ControllerStatus
	var linkUp: Bool
	/// macOS is refusing this app the local network.
	var networkDenied: Bool
	/// The other Mac's protocol version, once it has said it differs from ours.
	var otherVersion: UInt8?
	var roundTripMedianNanos: UInt64?
}

/// What the engine connects to and how it proves itself.
struct LinkPeer {
	let id: String
	let key: Data
	/// Typed by the person, for networks where discovery cannot work.
	let address: String?
}

/// `--selftest-loop` only: the peer is a loopback port, and the taps act only on events whose `eventSourceUserData`
/// has this tag in its upper 32 bits, so a person at the real mouse cannot change the result.
struct LoopbackTest {
	let port: UInt16
	let tag: UInt32
}

private func watchCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
	Unmanaged<ControllerEngine>.fromOpaque(refcon!).takeUnretainedValue().watch(type, event)
}

private func grabCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
	Unmanaged<ControllerEngine>.fromOpaque(refcon!).takeUnretainedValue().grab(type, event)
}

/// One thread with its own run loop owns `ControllerCore`, both taps, the socket, and the cursor. Main talks to it
/// through `perform` and hears back through `onReport` and `onSecureInput`, both delivered on main.
final class ControllerEngine {
	/// Grows on every timer pass and event. Main's watchdog reads it; a raw word keeps the hot path lock-free.
	let heartbeat = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
	/// True from before capture starts until after it ends, so main's watchdog also covers a stall while starting.
	let capturing = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

	private let onReport: (ControllerReport) -> Void
	private let onSecureInput: (Bool) -> Void
	private let peer: LinkPeer
	private let loopback: LoopbackTest?
	private let ready = DispatchSemaphore(value: 0)
	private var thread: Thread?
	private var loop: CFRunLoop!
	private var core: ControllerCore
	private var displays: Displays
	private var link: LinkClient?
	private var networkDenied = false
	/// Each attempt alternates when an address was typed, so that address and discovery each get a chance.
	private var tries = 0
	private var linkStarted: Tick = 0
	private var linkUp = false
	private var lastAnswer: Tick = 0
	private var otherVersion: UInt8?
	private var watchTap: CFMachPort?
	/// Exists only during capture. Turning off Accessibility while a consuming tap exists can hang all input until a
	/// forced restart (developer.apple.com/forums/thread/844416), and on the keyboard Mac that is done while local.
	private var grabTap: CFMachPort?
	private var retiredTap: CFMachPort?
	private var grabWanted = false
	private var secureTicks = 0
	private var captureRoundTrips: [UInt64] = []
	private var tickTimer: CFRunLoopTimer!
	private var housekeepingTimer: CFRunLoopTimer!
	private var parkTimer: CFRunLoopTimer?
	private var parkAt = CGPoint.zero
	private var hideDepth = 0
	private var cursorPropertySet = false
	private var trackedFlags: UInt64 = 0
	private var heldButtons = Set<Int>()
	private var roundTrips: [UInt64] = []
	private var pendingFault: ReturnReason?
	private var passes = 0
	private var lastReport: ControllerReport?
	private var lastReportAt: Tick = 0

	init(peer: LinkPeer, edge: Edge, loopback: LoopbackTest? = nil, onReport: @escaping (ControllerReport) -> Void, onSecureInput: @escaping (Bool) -> Void) {
		self.peer = peer
		self.loopback = loopback
		self.onReport = onReport
		self.onSecureInput = onSecureInput
		heartbeat.initialize(to: 0)
		capturing.initialize(to: false)
		displays = activeDisplays()
		core = ControllerCore(session: UInt32.random(in: 1...UInt32.max), edge: edge, displays: displays, now: monotonicNow())
		// The thread keeps the engine alive until its loop stops, so main may drop its reference any time.
		let t = Thread { [self] in run() }
		t.name = "mousey-controller"
		thread = t
		t.start()
		ready.wait()
	}

	deinit {
		heartbeat.deallocate()
		capturing.deallocate()
	}

	// MARK: Commands from main

	func perform(_ block: @escaping () -> Void) {
		CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
		CFRunLoopWakeUp(loop)
	}

	func fault(_ reason: ReturnReason) { perform { self.handle(.fault(reason)) } }

	func permissionGranted() { perform { self.createWatchTap() } }

	func setLocked(_ locked: Bool) { perform { self.handle(.locked(locked)) } }

	/// `--selftest-loop` only. Turns the grab tap off while it is still wanted, as the system does on a timeout.
	func disableGrabTapAsTheSystemWould() {
		perform { if let tap = self.grabTap { CGEvent.tapEnable(tap: tap, enable: false) } }
	}

	/// Returns input to this Mac, tears down the taps, and waits at most 100 ms.
	func terminate(_ reason: ReturnReason = .terminating) {
		let done = DispatchSemaphore(value: 0)
		perform {
			self.handle(.fault(reason))
			for tap in [self.watchTap, self.grabTap, self.retiredTap].compactMap({ $0 }) {
				CGEvent.tapEnable(tap: tap, enable: false)
				CFMachPortInvalidate(tap)
			}
			self.watchTap = nil
			self.grabTap = nil
			self.retiredTap = nil
			self.closeLink()
			CFRunLoopStop(self.loop)
			done.signal()
		}
		_ = done.wait(timeout: .now() + .milliseconds(100))
	}

	// MARK: Engine thread

	private func run() {
		setRealtimePolicy()
		loop = CFRunLoopGetCurrent()
		CGAssociateMouseAndMouseCursorPosition(1)
		tickTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 1e9, 0, 0) { [unowned self] _ in
			beat()
			handle(.tick)
		}
		housekeepingTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0) { [unowned self] _ in housekeeping() }
		CFRunLoopAddTimer(loop, tickTimer, .commonModes)
		CFRunLoopAddTimer(loop, housekeepingTimer, .commonModes)
		createWatchTap()
		rescan()
		ready.signal()
		CFRunLoopRun()
	}

	private func beat() { heartbeat.pointee &+= 1 }

	@discardableResult
	private func handle(_ input: ControllerInput) -> ControllerOutput {
		let now = monotonicNow()
		let out = core.handle(input, now: now)
		for effect in out.effects {
			switch effect {
			case .send(let frame): send(Wire.encode(frame))
			case .beginCapture(let at): beginCapture(at)
			case .endCapture(let to): endCapture(to)
			case .roundTrip(let nanos):
				roundTrips.append(nanos)
				if roundTrips.count > 32 { roundTrips.removeFirst() }
				if grabWanted, captureRoundTrips.count < 4000 { captureRoundTrips.append(nanos) }
			}
		}
		let delay = out.nextTick > now ? Double(out.nextTick - now) / 1e9 : 0
		CFRunLoopTimerSetNextFireDate(tickTimer, CFAbsoluteTimeGetCurrent() + delay)
		report(now: now)
		if let fault = pendingFault {
			pendingFault = nil
			handle(.fault(fault))
		}
		return out
	}

	private func createWatchTap() {
		guard watchTap == nil, let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
			eventsOfInterest: Classify.motionMask, callback: watchCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
		watchTap = tap
		CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
	}

	fileprivate func watch(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
		beat()
		let pass = Unmanaged.passUnretained(event)
		if Classify.tapDisabledTypes.contains(type.rawValue) {
			if let watchTap { CGEvent.tapEnable(tap: watchTap, enable: true) }
			return pass
		}
		guard isTagged(event), case .motion(let dx, let dy) = Classify.action(for: event) else { return pass }
		let out = handle(.watchMotion(location: event.location, dx: dx, dy: dy, buttonsHeld: type != .mouseMoved))
		if out.effects.contains(where: { if case .beginCapture = $0 { return true } else { return false } }) {
			handle(.grabbedMotion(dx: 0, dy: 0, bytes: bytes(of: event)))
		}
		return pass
	}

	fileprivate func grab(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
		beat()
		let pass = Unmanaged.passUnretained(event)
		if Classify.tapDisabledTypes.contains(type.rawValue) {
			// Turning a tap off in code delivers this same event, so only a wanted tap that is really off is a failure.
			if grabWanted, let grabTap, !CGEvent.tapIsEnabled(tap: grabTap) { handle(.fault(.tapDisabled)) }
			return pass
		}
		guard grabWanted, isTagged(event) else { return pass }
		let action = Classify.action(for: event)
		switch action {
		case .consume: return nil
		case .pass: return pass
		case .motion, .input: break
		}
		// A consuming tap also swallows modifier presses, so later events may lack their flags. The union is harmless
		// when they already carry them. Anything the core passes back to this Mac gets its own flags back.
		if type == .flagsChanged { trackedFlags = event.flags.rawValue }
		let ownFlags = event.flags
		let flags = ownFlags.rawValue | trackedFlags
		event.flags = CGEventFlags(rawValue: flags)
		let out: ControllerOutput
		switch action {
		case .motion(let dx, let dy):
			// Whether motion after a consumed mouse down still arrives as a drag is unknown, so make it one.
			if type == .mouseMoved, let button = heldButtons.min() {
				event.type = button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
				event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
			}
			out = handle(.grabbedMotion(dx: dx, dy: dy, bytes: bytes(of: event)))
		case .input(let input):
			if case .button(let index, let isDown) = input {
				if isDown { heldButtons.insert(index) } else { heldButtons.remove(index) }
			}
			out = handle(.grabbed(input, bytes: bytes(of: event), flags: flags))
		case .consume, .pass:
			return pass
		}
		if out.disposition == .pass {
			event.flags = ownFlags
			return pass
		}
		return nil
	}

	private func isTagged(_ event: CGEvent) -> Bool {
		guard let loopback else { return true }
		return UInt64(bitPattern: event.getIntegerValueField(.eventSourceUserData)) >> 32 == UInt64(loopback.tag)
	}

	private func bytes(of event: CGEvent) -> Data { event.data.map { $0 as Data } ?? Data() }

	// MARK: Effects

	private func send(_ data: Data) { link?.send(data) }

	private func beginCapture(_ at: CGPoint) {
		let started = monotonicNow()
		capturing.pointee = true
		grabWanted = true
		if loopback == nil {
			AwdlLease.shared.hold()
			ClipboardSync.noteLeaving()
		}
		guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: ~0,
			callback: grabCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return pendingFault = .tapDisabled }
		grabTap = tap
		CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
		if !cursorPropertySet {
			cursorPropertySet = true
			_ = CGS.setCursorInBackground()
		}
		hide()
		parkAt = at
		CGWarpMouseCursorPosition(at)
		CGAssociateMouseAndMouseCursorPosition(0)
		let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0) { [unowned self] _ in
			// Hide first, then show, so the count never reaches zero and the cursor never flashes. A count that kept growing
			// would take thousands of calls to undo on the way back, after a long session on the other Mac.
			if CGDisplayHideCursor(CGMainDisplayID()) == .success { CGDisplayShowCursor(CGMainDisplayID()) }
			if let l = CGEvent(source: nil)?.location, abs(l.x - parkAt.x) > 1 || abs(l.y - parkAt.y) > 1 {
				CGWarpMouseCursorPosition(parkAt)
				CGAssociateMouseAndMouseCursorPosition(0)
			}
			// A dead tap can stop delivering its disabled message, and acks would keep capture going with no way back.
			if let grabTap, !CGEvent.tapIsEnabled(tap: grabTap) {
				handle(.fault(.tapDisabled))
				return
			}
			checkSecureInput()
		}
		CFRunLoopAddTimer(loop, timer, .commonModes)
		parkTimer = timer
		secureTicks = 0
		checkSecureInput()
		Log.write("capture begins, parked at \(at), setup \(milliseconds(since: started))")
	}

	/// Secure input hides keys from the tap, so they would go to the field on this Mac while the pointer is on the other.
	/// Taking focus usually ends it. If it stays on, return rather than send a password to the wrong Mac.
	private func checkSecureInput() {
		guard IsSecureEventInputEnabled() else { return secureTicks = 0 }
		secureTicks += 1
		if secureTicks == 1 { DispatchQueue.main.async { [onSecureInput] in onSecureInput(true) } }
		if secureTicks >= 3 { handle(.fault(.secureInput)) }
	}

	private func milliseconds(since start: Tick) -> String { String(format: "%.2f ms", Double(monotonicNow() - start) / 1e6) }

	/// Idempotent. Everything here is harmless to repeat.
	private func endCapture(_ to: CGPoint) {
		let started = monotonicNow()
		if let parkTimer { CFRunLoopTimerInvalidate(parkTimer) }
		parkTimer = nil
		grabWanted = false
		if let grabTap {
			CGEvent.tapEnable(tap: grabTap, enable: false)
			// This can run inside the tap's own callback, which still has to return through the port.
			retiredTap = grabTap
			CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
				if let retiredTap { CFMachPortInvalidate(retiredTap) }
				retiredTap = nil
			}
			CFRunLoopWakeUp(loop)
		}
		grabTap = nil
		CGWarpMouseCursorPosition(to)
		CGAssociateMouseAndMouseCursorPosition(1)
		while hideDepth > 0 {
			CGDisplayShowCursor(CGMainDisplayID())
			hideDepth -= 1
		}
		trackedFlags = 0
		heldButtons = []
		capturing.pointee = false
		if loopback == nil {
			AwdlLease.shared.letGo()
			ClipboardSync.noteArriving()
		}
		DispatchQueue.main.async { [onSecureInput] in onSecureInput(false) }
		let reason = core.status.lastReturn.map { "\($0)" } ?? "unknown"
		Log.write("capture ends: \(reason), back at \(to), teardown \(milliseconds(since: started)), round trip \(latencySummary(captureRoundTrips)) over \(captureRoundTrips.count)")
		captureRoundTrips.removeAll(keepingCapacity: true)
	}

	private func hide() {
		if CGDisplayHideCursor(CGMainDisplayID()) == .success { hideDepth += 1 }
	}

	// MARK: Socket

	/// Makes sure a link exists to the best known address. A silent link is replaced, because the other side may have
	/// restarted, and its old session can never answer again.
	private func rescan() {
		let now = monotonicNow()
		if link != nil, now - max(lastAnswer, linkStarted) > 3_000_000_000 { closeLink() }
		guard link == nil else { return }
		let endpoint: NWEndpoint
		if let loopback {
			endpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: loopback.port)!)
		} else if let address = peer.address, tries % 2 == 0 {
			endpoint = linkEndpoint(address: address)
		} else {
			endpoint = SecureLink.endpoint(peerID: peer.id)
		}
		tries &+= 1
		linkStarted = now
		// Weak, because these system callbacks can arrive after the engine has stopped.
		link = LinkClient(endpoint: endpoint, key: peer.key, loopback: loopback != nil, onPacket: { [weak self] data in
			self?.perform { self?.drain(data) }
		}, onState: { [weak self] state in
			self?.perform { self?.linkState(state) }
		})
		handle(.tick)
	}

	private func linkState(_ state: NWConnection.State) {
		switch state {
		case .ready:
			linkUp = true
			networkDenied = false
			Log.write("link up")
		case .failed(let error):
			Log.write("link failed: \(error)")
			closeLink()
			handle(.fault(.socketError))
		case .waiting(let error):
			linkUp = false
			if case .dns(let code) = error, code == SecureLink.policyDenied { networkDenied = true }
		default:
			break
		}
		report(now: monotonicNow())
	}

	private func closeLink() {
		link?.cancel()
		link = nil
		linkUp = false
	}

	private func drain(_ data: Data) {
		beat()
		lastAnswer = monotonicNow()
		if let ack = Wire.decodeAck(data) {
			otherVersion = nil
			handle(.ack(ack))
		} else if let version = Wire.decodeVersionNotice(data), otherVersion != version {
			otherVersion = version
			Log.write("the other Mac runs protocol version \(version), this one \(Wire.version)")
			report(now: monotonicNow())
		}
	}

	// MARK: Once a second

	private func housekeeping() {
		beat()
		// Idempotent, so a helper installed or restarted during a session is picked up.
		if grabWanted, loopback == nil { AwdlLease.shared.hold() }
		createWatchTap()
		if let watchTap, !CGEvent.tapIsEnabled(tap: watchTap) { CGEvent.tapEnable(tap: watchTap, enable: true) }
		let found = activeDisplays()
		if found != displays {
			displays = found
			handle(.localDisplays(found))
		}
		passes += 1
		rescan()
		report(now: monotonicNow())
	}

	private func report(now: Tick) {
		// This runs on every event, so the cheap checks come before the sort.
		guard core.status.isRemote != lastReport?.core.isRemote || now - lastReportAt >= 250_000_000 else { return }
		lastReportAt = now
		let median = roundTrips.isEmpty ? nil : roundTrips.sorted()[roundTrips.count / 2]
		let r = ControllerReport(core: core.status, linkUp: linkUp, networkDenied: networkDenied, otherVersion: otherVersion, roundTripMedianNanos: median)
		guard r != lastReport else { return }
		lastReport = r
		DispatchQueue.main.async { [onReport] in onReport(r) }
	}
}
