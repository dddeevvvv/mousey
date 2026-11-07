#if DEBUG
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MouseyCore

// The modes in this file post real events, so they move the pointer and type on this Mac, and no one should be using
// it while they run. Each refuses without Accessibility and never prompts. Launch them with `open -n` so the permission
// is the app's own, and keep the recording outside ~/Documents, where reading it raises another permission prompt.

private let logFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mousey")

/// A floating window of our own to post at, a monitor of what reaches us, a PASS/FAIL log, and a hard stop that
/// restores the cursor from another thread. Every exit path goes through `finish`.
final class InjectHarness {
	let window: NSWindow
	let field = NSTextField(frame: NSRect(x: 20, y: 540, width: 860, height: 28))
	var seen: [NSEvent] = []
	/// Events that were already old when they reached us. Recorded on arrival, because age grows while a test waits.
	var late = 0
	let logURL: URL
	let savedCursor = CGEvent(source: nil)?.location ?? .zero
	private var lines: [String] = []
	private(set) var failed = 0
	private var cleanup: () -> Void = {}

	init(log: String, hardStopSeconds: Double, cleanup: @escaping () -> Void) {
		logURL = logFolder.appendingPathComponent(log)
		self.cleanup = cleanup
		let screen = CGDisplayBounds(CGMainDisplayID())
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
		window.title = "Mousey self-test"
		window.level = .floating
		window.collectionBehavior = [.canJoinAllSpaces]
		window.contentView?.addSubview(field)
		window.setFrameOrigin(NSPoint(x: screen.midX - 450, y: NSScreen.screens[0].frame.height - screen.midY - 300))
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		window.makeFirstResponder(field)
		NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] e in
			self?.seen.append(e)
			// Posting loops hold this thread for up to about 1.5 s, so 3 s separates a queue from a recording's old clock.
			if abs(ProcessInfo.processInfo.systemUptime - e.timestamp) > 3 { self?.late += 1 }
			return e
		}
		for sig in [SIGINT, SIGTERM] {
			signal(sig, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
			source.setEventHandler { [self] in finish(130, "signal") }
			source.resume()
			signals.append(source)
		}
		let stop = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mousey-hard-stop"))
		stop.schedule(deadline: .now() + hardStopSeconds)
		stop.setEventHandler { [self] in
			cleanup()
			Self.restoreCursor(to: savedCursor)
			lines.append("FAIL: hard stop after \(hardStopSeconds) s")
			writeLog()
			_exit(3)
		}
		stop.resume()
		hardStop = stop
	}

	private var signals: [DispatchSourceSignal] = []
	private var hardStop: DispatchSourceTimer?

	/// A point inside our window, in global display coordinates (origin top-left).
	func inside(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
		let f = window.frame
		return CGPoint(x: f.minX + dx, y: NSScreen.screens[0].frame.height - f.maxY + dy)
	}

	/// True when the window server says our window is the topmost on-screen window at `p`.
	func windowIsFrontmost(at p: CGPoint) -> Bool {
		guard window.isKeyWindow, window.isOnActiveSpace,
			let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
		for info in list {
			guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat], info[kCGWindowLayer as String] as? Int ?? 0 <= Int(window.level.rawValue) else { continue }
			let r = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
			guard r.contains(p) else { continue }
			return info[kCGWindowNumber as String] as? Int == window.windowNumber
		}
		return false
	}

	func check(_ ok: Bool, _ what: String) {
		if !ok { failed += 1 }
		note("\(ok ? "PASS" : "FAIL"): \(what)")
	}

	func note(_ line: String) {
		lines.append(line)
		print(line)
	}

	func describe(_ e: NSEvent) -> String {
		var s = "type \(e.type.rawValue) flags \(String(e.modifierFlags.rawValue, radix: 16)) age \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - e.timestamp)) s"
		switch e.type {
		case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
			s += " clicks \(e.clickCount) button \(e.buttonNumber) delta (\(e.deltaX), \(e.deltaY))"
		case .scrollWheel:
			s += " phase \(e.phase.rawValue) momentum \(e.momentumPhase.rawValue) delta (\(e.scrollingDeltaX), \(e.scrollingDeltaY)) precise \(e.hasPreciseScrollingDeltas)"
		case .magnify: s += " phase \(e.phase.rawValue) magnification \(e.magnification)"
		case .rotate: s += " phase \(e.phase.rawValue) rotation \(e.rotation)"
		case .gesture, .swipe, .smartMagnify, .pressure: s += " phase \(e.phase.rawValue)"
		case .keyDown, .keyUp, .flagsChanged: s += " keyCode \(e.keyCode)"
		default: break
		}
		return s
	}

	func finish(_ code: Int32, _ reason: String) -> Never {
		hardStop?.cancel()
		cleanup()
		Self.restoreCursor(to: savedCursor)
		lines.append("finished with code \(code): \(reason), \(failed) failures")
		writeLog()
		print("log: \(logURL.path)")
		exit(code)
	}

	static func restoreCursor(to p: CGPoint) {
		CGAssociateMouseAndMouseCursorPosition(1)
		CGWarpMouseCursorPosition(p)
		for _ in 0..<4 { CGDisplayShowCursor(CGMainDisplayID()) }
	}

	private func writeLog() {
		try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
		try? Data((["\(Date())"] + lines).joined(separator: "\n").appending("\n").utf8).write(to: logURL)
	}
}

/// Runs `steps` on the main run loop, `gap` seconds apart, then `done`.
private func sequence(_ steps: [() -> Void], gap: Double, done: @escaping () -> Void) {
	var remaining = steps
	func next() {
		guard !remaining.isEmpty else { return done() }
		remaining.removeFirst()()
		DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: next)
	}
	next()
}

private func refuseWithoutPermission(_ mode: String) {
	guard !CGPreflightPostEventAccess() else { return }
	print("\(mode) refused: this process may not post events. Grant Accessibility to the app, do not expect a prompt.")
	exit(2)
}

private func keyData(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) -> Data {
	let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
	e.flags = flags
	return e.data! as Data
}

private func flagsData(_ code: CGKeyCode, flags: CGEventFlags) -> Data { flagsChanged(UInt16(code), flags: flags.rawValue).data! as Data }

// MARK: --selftest-inject

func runSelfTestInject(recording path: String) -> Never {
	refuseWithoutPermission("--selftest-inject")
	guard let log = loadRecording(path) else {
		print("cannot read \(path)")
		exit(1)
	}
	let app = NSApplication.shared
	app.setActivationPolicy(.accessory)
	let h = InjectHarness(log: "selftest-inject.txt", hardStopSeconds: 60, cleanup: {})
	let blobs = log.steps.flatMap { step in step.blobs.map { (step: step.name, blob: $0) } }
	func first(_ type: UInt32, where test: (CGEvent) -> Bool = { _ in true }) -> Data? {
		blobs.first { $0.blob.type == type && rebuild($0.blob.data).map(test) == true }?.blob.data
	}
	let center = h.inside(450, 300)
	var mark = 0
	func arrived() -> [NSEvent] { Array(h.seen[min(mark, h.seen.count)...]) }
	func postGestures(_ withTouches: Bool) -> Int {
		var n = 0
		for b in blobs where b.step == "pinch_rotate" && b.blob.type == 29 {
			if !withTouches, rebuild(b.blob.data)?.getIntegerValueField(Classify.Field.gestureSubtype) == 0 { continue }
			Replay.perform(.post(bytes: b.blob.data, at: center))
			n += 1
			usleep(4000)
		}
		return n
	}
	var gestureCounts: [String] = []

	DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
		sequence([
			{
				h.note("window at \(h.window.frame), posting at \(center)")
				Replay.perform(.postMotion(bytes: first(5)!, at: h.inside(100, 100)))
			},
			{
				let l = CGEvent(source: nil)?.location ?? .zero
				let want = h.inside(100, 100)
				h.check(abs(l.x - want.x) <= 2 && abs(l.y - want.y) <= 2, "pointer moved by Replay to \(want), read back \(l)")
				Replay.perform(.postMotion(bytes: first(5)!, at: center))
			},
			{
				guard h.windowIsFrontmost(at: center) else {
					h.check(false, "our window is not key, on the active space, and frontmost at \(center). Stopping before any click.")
					h.finish(1, "unsafe to click")
				}
				h.note("safety: our window is key and frontmost at \(center)")
				mark = h.seen.count
				Replay.perform(.post(bytes: first(1) { $0.getIntegerValueField(.mouseEventClickState) == 1 }!, at: center))
				Replay.perform(.post(bytes: first(2) { $0.getIntegerValueField(.mouseEventClickState) == 1 }!, at: center))
			},
			{
				let downs = arrived().filter { $0.type == .leftMouseDown }
				h.check(downs.first?.clickCount == 1, "single click arrives with click count 1: \(downs.map(h.describe))")
				mark = h.seen.count
				Replay.perform(.post(bytes: first(1) { $0.getIntegerValueField(.mouseEventClickState) == 2 }!, at: center))
				Replay.perform(.post(bytes: first(2) { $0.getIntegerValueField(.mouseEventClickState) == 2 }!, at: center))
			},
			{
				let downs = arrived().filter { $0.type == .leftMouseDown }
				h.check(downs.first?.clickCount == 2, "double click arrives with click count 2: \(downs.map(h.describe))")
				mark = h.seen.count
				Replay.perform(.post(bytes: first(1) { $0.getIntegerValueField(.mouseEventClickState) == 1 }!, at: center))
				for (i, b) in blobs.filter({ $0.blob.type == 6 }).prefix(8).enumerated() {
					Replay.perform(.postMotion(bytes: b.blob.data, at: h.inside(450 + CGFloat(i) * 5, 300 + CGFloat(i) * 3)))
					usleep(8000)
				}
				Replay.perform(.post(bytes: first(2) { $0.getIntegerValueField(.mouseEventClickState) == 1 }!, at: h.inside(490, 324)))
			},
			{
				let drags = arrived().filter { $0.type == .leftMouseDragged }
				h.check(!drags.isEmpty, "drag from real type 6 blobs: \(drags.count) leftMouseDragged arrived")
				h.field.stringValue = ""
				h.window.makeFirstResponder(h.field)
				mark = h.seen.count
				let shift: CGEventFlags = [.maskShift, CGEventFlags(rawValue: 0x2)]
				for bytes in [keyData(0, down: true), keyData(0, down: false), keyData(11, down: true), keyData(11, down: false),
					flagsData(56, flags: shift), keyData(8, down: true, flags: shift), keyData(8, down: false, flags: shift), flagsData(56, flags: [])] {
					Replay.perform(.post(bytes: bytes, at: center))
					usleep(15000)
				}
			},
			{
				h.check(h.field.stringValue == "abC", "typing a, b, shift+c through CGEvent.data reads \"\(h.field.stringValue)\"")
				mark = h.seen.count
				var previous: UInt64?
				for b in blobs where b.step == "scroll" && b.blob.type == 22 {
					if let e = rebuild(b.blob.data) {
						if let p = previous, e.timestamp > p { usleep(UInt32(min((e.timestamp - p) * UInt64(log.clocks.timebaseNumer) / UInt64(log.clocks.timebaseDenom) / 1000, 20000))) }
						previous = e.timestamp
					}
					Replay.perform(.post(bytes: b.blob.data, at: center))
				}
			},
			{
				// NSEvent numbers phases differently from CGEvent, and AppKit merges same-phase scrolls while this thread is busy posting.
				let nsPhase = [0: 0, 1: 1, 2: 4, 4: 8, 8: 16, 128: 32], nsMomentum = [0: 0, 1: 1, 2: 4, 3: 8]
				func runs(_ phases: [[Int]]) -> [[Int]] { phases.reduce(into: []) { if $0.last != $1 { $0.append($1) } } }
				let posted = runs(blobs.filter { $0.step == "scroll" && $0.blob.type == 22 }.compactMap(\.blob.data).compactMap(rebuild)
					.map { [nsPhase[Int($0.getIntegerValueField(.scrollWheelEventScrollPhase))] ?? -1, nsMomentum[Int($0.getIntegerValueField(.scrollWheelEventMomentumPhase))] ?? -1] })
				let got = runs(arrived().filter { $0.type == .scrollWheel }.map { [Int($0.phase.rawValue), Int($0.momentumPhase.rawValue)] })
				h.check(got == posted, "scroll phases and momentum phases arrive in order: posted \(posted.count) runs, arrived \(got.count) runs" + (got == posted ? "" : "\n  posted \(posted)\n  arrived \(got)"))
				h.check(arrived().filter { $0.type == .scrollWheel }.allSatisfy(\.hasPreciseScrollingDeltas), "scroll deltas are precise")
				mark = h.seen.count
				gestureCounts.append("with touches: posted \(postGestures(true))")
			},
			{
				let magnify = arrived().filter { $0.type == .magnify }.count, rotate = arrived().filter { $0.type == .rotate }.count
				gestureCounts[0] += ", magnify \(magnify), rotate \(rotate), other gesture \(arrived().filter { $0.type == .gesture }.count)"
				h.check(magnify > 0, "pinch with touch events: magnify arrives (\(gestureCounts[0]))")
				mark = h.seen.count
				gestureCounts.append("without touches: posted \(postGestures(false))")
			},
			{
				let magnify = arrived().filter { $0.type == .magnify }.count, rotate = arrived().filter { $0.type == .rotate }.count
				gestureCounts[1] += ", magnify \(magnify), rotate \(rotate), other gesture \(arrived().filter { $0.type == .gesture }.count)"
				h.check(magnify > 0, "pinch without touch events: magnify arrives (\(gestureCounts[1]))")
				h.note("rotate events: \(gestureCounts.joined(separator: "; ")). The recording holds no rotate subtype, so this is reported, not judged.")
				h.check(h.late == 0, "every event's timestamp is current on arrival (\(h.seen.count) events, \(h.late) late)")
			},
		], gap: 0.5) { h.finish(h.failed == 0 ? 0 : 1, "done") }
	}
	app.run()
	exit(0)
}

// MARK: --selftest-dock

/// Replays the `swipe` step's types 29 and 30 at the current pointer, at the recorded pace, and reports what it posted.
func runSelfTestDock(recording path: String) -> Never {
	refuseWithoutPermission("--selftest-dock")
	guard let log = loadRecording(path), let swipe = log.steps.first(where: { $0.name == "swipe" }) else {
		print("cannot read \(path) or it has no swipe step")
		exit(1)
	}
	let at = CGEvent(source: nil)?.location ?? .zero
	var counts: [String: Int] = [:]
	var previous: UInt64?
	for b in swipe.blobs where [29, 30].contains(b.type) {
		guard let e = rebuild(b.data) else { continue }
		if let p = previous, e.timestamp > p { usleep(UInt32(min((e.timestamp - p) / 1000, 50000))) }
		previous = e.timestamp
		Replay.perform(.post(bytes: b.data, at: at))
		counts["type \(b.type) subtype \(e.getIntegerValueField(Classify.Field.gestureSubtype)) phase \(e.getIntegerValueField(Classify.Field.gesturePhase))", default: 0] += 1
	}
	let report = counts.sorted { $0.key < $1.key }.map { "\($0.value) x \($0.key)" }.joined(separator: "\n")
	print("posted at \(at):\n\(report)")
	try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
	try? Data("\(Date())\nposted at \(at):\n\(report)\n".utf8).write(to: logFolder.appendingPathComponent("selftest-dock.txt"))
	exit(0)
}

// MARK: --selftest-loop

/// The real controller engine with real taps, on this Mac, against a loopback `TargetCore` whose replay is captured.
/// Input comes from posted events that carry a tag, so a person at the real mouse cannot change the result.
func runSelfTestLoop(recording path: String) -> Never {
	refuseWithoutPermission("--selftest-loop")
	let app = NSApplication.shared
	app.setActivationPolicy(.accessory)
	let capture = Capture()
	Replay.post = { capture.events.append($0) }
	var engine: ControllerEngine?
	var target: LoopbackTarget?
	let h = InjectHarness(log: "selftest-loop.txt", hardStopSeconds: 20) {
		engine?.terminate()
		target?.stop()
	}
	let tag: UInt32 = 0x4B4D_5450
	let source = CGEventSource(stateID: .privateState)!
	source.userData = Int64(tag) << 32
	let screen = CGDisplayBounds(CGMainDisplayID())
	let edge = CGPoint(x: screen.maxX - 0.5, y: screen.midY)
	let park = CGPoint(x: screen.midX, y: screen.midY)
	let warpBack = CGPoint(x: screen.maxX - 2, y: screen.midY)
	var report: ControllerReport?
	func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
	func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 }
	func post(_ e: CGEvent) { e.post(tap: .cghidEventTap) }
	func motion(at p: CGPoint, dx: Int64) {
		let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
		e.setIntegerValueField(.mouseEventDeltaX, value: dx)
		post(e)
	}
	func cross() {
		for _ in 0..<6 {
			motion(at: edge, dx: 6)
			usleep(30000)
		}
	}
	func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
		let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
		e.flags = flags
		post(e)
	}
	func modifier(_ code: CGKeyCode, flags: CGEventFlags) {
		let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)!
		e.type = .flagsChanged
		e.flags = flags
		post(e)
	}
	var mark = 0
	var consumed = false

	guard activeDisplays().isOuter(.right, of: screen, at: edge) else {
		h.check(false, "the main display's right edge is not an outer edge, so this layout cannot be used")
		h.finish(1, "layout")
	}
	h.check(AXIsProcessTrusted(), "Accessibility is granted (taps need it)")
	guard let t = LoopbackTarget(displays: Displays([CGRect(x: 0, y: 0, width: 2560, height: 1440)])) else { h.finish(1, "no loopback target") }
	target = t
	t.start()
	engine = ControllerEngine(peer: LinkPeer(id: "selftest", key: LoopbackTarget.key, address: nil), edge: .right, loopback: LoopbackTest(port: t.port, tag: tag),
		onReport: { report = $0 }, onSecureInput: { _ in })

	DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
		sequence([
			{
				h.check(report?.core.targetOnline == true, "the engine hears the loopback target: \(String(describing: report?.core))")
				h.note("cursor at \(cursor()), posting the first crossing at \(edge)")
				cross()
			},
			{
				h.check(report?.core.isRemote == true, "crossing 1: posted motion at the edge crosses after the push gate (\(String(describing: report?.core)))")
				h.check(near(cursor(), park), "cursor parked at \(park), read back \(cursor())")
				engine?.fault(.disabled)
			},
			{
				h.check(report?.core.isRemote == false && report?.core.lastReturn == .disabled, "a fault returns control (\(String(describing: report?.core)))")
				h.check(near(cursor(), warpBack), "cursor warped back to the departure edge \(warpBack), read back \(cursor())")
				cross()
			},
			{
				h.check(report?.core.isRemote == true, "crossing 2 holds after our own disable of the grab tap (\(String(describing: report?.core)))")
				mark = capture.events.count
				for i in 0..<5 {
					motion(at: CGPoint(x: park.x + CGFloat(i) * 40, y: park.y), dx: 40)
					usleep(20000)
				}
			},
			{
				let motions = capture.events[min(mark, capture.events.count)...].filter { Classify.motionTypes.contains($0.type.rawValue) }
				consumed = near(cursor(), park) && !motions.isEmpty && report?.core.isRemote == true
				h.check(consumed, "the grab tap consumes while remote: cursor still at \(park) (read back \(cursor())), \(motions.count) motions reached the capturing poster")
				guard consumed, h.windowIsFrontmost(at: park) else {
					return h.note("skipping keys and clicks: consumption unverified or our window is not frontmost at the park point, so a leak could reach another app")
				}
				mark = capture.events.count
				let before = h.seen.count
				key(0, down: true)
				key(0, down: false)
				let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: park, mouseButton: .left)!
				let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: park, mouseButton: .left)!
				post(down)
				post(up)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
					let got = capture.events[min(mark, capture.events.count)...].filter { !Classify.motionTypes.contains($0.type.rawValue) }
						.map { "\($0.type.rawValue)" + ($0.type == .keyDown || $0.type == .keyUp ? "/key\($0.getIntegerValueField(.keyboardEventKeycode))" : "") }
					h.check(got == ["10/key0", "11/key0", "1", "2"], "keys and clicks posted while remote reach the poster in order: \(got)")
					h.check(h.seen.count == before && h.field.stringValue.isEmpty, "nothing leaked to our own window (\(h.seen.count - before) events, field \"\(h.field.stringValue)\")")
				}
			},
			{ h.note("holding capture") },
			{ h.note("holding capture") },
			{ h.note("holding capture") },
			{
				h.check(report?.core.isRemote == true, "capture held for 3 s (\(String(describing: report?.core)))")
				let control: CGEventFlags = [.maskControl, CGEventFlags(rawValue: 0x1)]
				let option: CGEventFlags = [.maskAlternate, CGEventFlags(rawValue: 0x20)]
				let command: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x8)]
				modifier(59, flags: control)
				modifier(58, flags: control.union(option))
				modifier(55, flags: control.union(option).union(command))
				key(53, down: true, flags: [.maskControl, .maskAlternate, .maskCommand])
				key(53, down: false, flags: [.maskControl, .maskAlternate, .maskCommand])
				modifier(55, flags: control.union(option))
				modifier(58, flags: control)
				modifier(59, flags: [])
			},
			{
				h.check(report?.core.isRemote == false && report?.core.lastReturn == .panicChord, "the panic chord returns control (\(String(describing: report?.core)))")
				h.check(near(cursor(), warpBack), "cursor restored to \(warpBack), read back \(cursor())")
				motion(at: park, dx: 1)
			},
			{
				h.check(near(cursor(), park), "posted motion moves the cursor again after the return (association restored, read back \(cursor()))")
				cross()
			},
			{
				h.check(report?.core.isRemote == true, "crossing 3 (\(String(describing: report?.core)))")
				engine?.disableGrabTapAsTheSystemWould()
			},
			{
				h.check(report?.core.isRemote == false && report?.core.lastReturn == .tapDisabled, "a system-style disable of a wanted grab tap feeds tapDisabled and returns control (\(String(describing: report?.core)))")
				h.check(near(cursor(), warpBack), "cursor restored to \(warpBack), read back \(cursor())")
				cross()
			},
			{
				h.check(report?.core.isRemote == true, "crossing 4 (\(String(describing: report?.core)))")
				EnableSecureEventInput()
			},
			{ h.note("holding secure input") },
			{
				h.check(report?.core.isRemote == false && report?.core.lastReturn == .secureInput, "secure input that stays on returns control (\(String(describing: report?.core)))")
				h.check(near(cursor(), warpBack), "cursor restored to \(warpBack), read back \(cursor())")
				DisableSecureEventInput()
			},
		], gap: 0.5) { h.finish(h.failed == 0 ? 0 : 1, "done") }
	}
	app.run()
	exit(0)
}
#endif
