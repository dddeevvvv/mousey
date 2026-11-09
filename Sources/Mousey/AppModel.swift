import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MouseyCore
import MouseyLease
import MouseyPair
import Network
import ServiceManagement
import SwiftUI

enum OnboardingStep: String, CaseIterable {
	case welcome, chooseRole, accessibility, pair, arrange, crossOver, wayOut, waitForKeyboard, smooth, done

	/// The keyboard Mac teaches. The controlled Mac mostly watches and confirms.
	static func sequence(for role: Role?) -> [OnboardingStep] {
		switch role {
		case .target: return [.welcome, .chooseRole, .accessibility, .pair, .waitForKeyboard, .smooth, .done]
		default: return [.welcome, .chooseRole, .accessibility, .pair, .arrange, .crossOver, .wayOut, .smooth, .done]
		}
	}
}

struct AppStatus: Equatable {
	var text: String
	var problem = false
	var active = false
	var fix = Fix.none

	enum Fix { case none, accessibility, localNetwork }
}

/// Everything the windows and the menu show, and the only owner of the engines. Main thread.
final class AppModel: ObservableObject {
	@Published var step: OnboardingStep
	@Published var role: Role?
	@Published var edge: Edge
	@Published var peerName: String?
	@Published var address: String?
	@Published private(set) var status = AppStatus(text: "Starting")
	@Published private(set) var trusted = AXIsProcessTrusted()
	@Published private(set) var nearby: [PairingBrowser.Found] = []
	@Published private(set) var browseTrouble = PairingBrowser.Trouble.none
	@Published private(set) var pairingPhase: Pairing.Phase?
	@Published private(set) var pairingPeer: String?
	@Published private(set) var askedForAccessibility = Settings.askedForAccessibility
	@Published private(set) var pairingMessage: String?
	@Published private(set) var pairingStopped = false
	@Published private(set) var crossed = false
	@Published private(set) var cameBack = false
	@Published private(set) var usedWayOut = false
	@Published private(set) var controlledNow = false
	@Published private(set) var wasControlled = false
	@Published private(set) var helperInstalled = false
	@Published private(set) var helperBusy = false
	@Published private(set) var helperMessage: String?
	@Published private(set) var clipboardOn = Settings.clipboardSharing
	@Published private(set) var clipboardConnected = false
	@Published private(set) var updateVersion: String?

	private var updates = Settings.updates {
		didSet {
			Settings.updates = updates
			showUpdate()
		}
	}
	private let keys = KeyStore()
	private var controller: ControllerEngine?
	private var target: TargetEngine?
	private var controllerReport: ControllerReport?
	private var targetReport: TargetReport?
	private var browser: PairingBrowser?
	private var pairingListener: PairingListener?
	private var channel: PairingChannel?
	private var gate = PairingGate()
	private var lastBeat: UInt64 = 0
	private var lastBeatChange = Date()
	private var focusToRestore = FocusToRestore<NSRunningApplication>()
	private var signalSources: [DispatchSourceSignal] = []
	private var activity: NSObjectProtocol?

	/// Shown in the title of nearby lists, and to the other Mac while pairing.
	var localName: String { Host.current().localizedName ?? "This Mac" }
	@Published private(set) var isPaired = false
	var onboardingFinished: Bool { step == .done && Settings.onboardingStep == OnboardingStep.done.rawValue }
	var addresses: [String] { localAddresses() }
	var edgeWord: String { Settings.edgeNames[edge] ?? "left" }

	init() {
		step = Settings.onboardingStep.flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
		role = Settings.role
		edge = Settings.edge
		peerName = Settings.peerName
		address = Settings.address
		isPaired = Settings.peerID != nil && keys.load() != nil
	}

	func start() {
		activity = ProcessInfo.processInfo.beginActivity(options: [.latencyCritical, .userInitiatedAllowingIdleSystemSleep], reason: "Forwarding input between Macs")
		observe()
		// Common modes, so these keep running while a menu or an alert is open.
		for (seconds, duty) in [(0.5, watchdog), (1, poll), (3600, checkForUpdate)] as [(Double, () -> Void)] {
			RunLoop.main.add(Timer(timeInterval: seconds, repeats: true) { _ in duty() }, forMode: .common)
		}
		poll()
		showUpdate()
		checkForUpdate()
		if step == .accessibility, trusted { advance() }
		if step == .pair { enterPairing() }
		startEngine()
		refreshStatus()
	}

	func terminate() { stopEngine() }

	// MARK: Tutorial

	func advance() {
		let sequence = OnboardingStep.sequence(for: role)
		guard let index = sequence.firstIndex(of: step), index + 1 < sequence.count else { return }
		go(to: sequence[index + 1])
	}

	func goBack() {
		let sequence = OnboardingStep.sequence(for: role)
		guard let index = sequence.firstIndex(of: step), index > 0 else { return }
		// Going back to a step that moves on by itself would land right back here.
		let previous = sequence[index - 1]
		if previous == .accessibility, trusted, index > 1 { return go(to: sequence[index - 2]) }
		go(to: previous)
	}

	func go(to next: OnboardingStep) {
		if step == .pair, next != .pair { leavePairing() }
		step = next
		Settings.onboardingStep = next.rawValue
		if next == .pair { enterPairing() }
		if next == .accessibility, trusted { advance() }
		refreshStatus()
	}

	func restartTutorial() {
		crossed = false
		cameBack = false
		usedWayOut = false
		wasControlled = false
		go(to: .welcome)
	}

	func choose(role chosen: Role) {
		if role != chosen {
			stopEngine()
			forgetPairing(keepingStep: true)
		}
		role = chosen
		Settings.role = chosen
		advance()
	}

	/// One at a time. macOS's dialog has its own button to open Settings, so opening Settings as well leaves the dialog waiting behind it.
	func requestAccessibility() {
		guard !Settings.askedForAccessibility else { return openAccessibilityPane() }
		Settings.askedForAccessibility = true
		askedForAccessibility = true
		AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
	}

	func openAccessibilityPane() { openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
	func openLocalNetworkPane() { openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") }

	func setEdge(_ new: Edge) {
		edge = new
		Settings.edge = new
		if role == .controller, isPaired { restartEngine() }
	}

	// MARK: Pairing

	private func enterPairing() {
		guard !isPaired else { return }
		// Safe to reach twice: a second listener could not bind the port and would report a false problem.
		leavePairing()
		pairingPhase = nil
		pairingPeer = nil
		pairingMessage = nil
		pairingStopped = false
		gate = PairingGate()
		switch role {
		case .controller:
			browser = PairingBrowser(onChange: { [weak self] in self?.nearby = $0 }, onTrouble: { [weak self] in self?.browseTrouble = $0 })
		case .target:
			pairingListener = PairingListener(name: localName, onState: { [weak self] state in
				switch state {
				case .waiting, .failed: self?.pairingMessage = "This Mac cannot be found yet. Allow Mousey under System Settings, Privacy & Security, Local Network, and allow incoming connections if your firewall asks."
				case .ready: self?.pairingMessage = nil
				default: break
				}
			}, onConnection: { [weak self] connection in self?.answer(connection) })
		case nil:
			break
		}
	}

	private func leavePairing() {
		browser?.stop()
		browser = nil
		pairingListener?.stop()
		pairingListener = nil
		channel?.close()
		channel = nil
		nearby = []
	}

	/// After the limit on attempts, or for a person who wants another go.
	func retryPairing() {
		leavePairing()
		enterPairing()
	}

	func pair(with found: PairingBrowser.Found) {
		pairingPeer = found.name
		address = nil
		connect(to: found.endpoint)
	}

	func pair(withAddress text: String) {
		let typed = text.trimmingCharacters(in: .whitespaces)
		guard !typed.isEmpty else { return }
		pairingPeer = typed
		address = typed
		connect(to: .hostPort(host: NWEndpoint.Host(typed), port: SecureLink.pairingPort))
	}

	private func connect(to endpoint: NWEndpoint) {
		pairingMessage = nil
		channel?.cancel()
		let made = makeChannel(.initiator)
		channel = made
		made.attach(NWConnection(to: endpoint, using: .tcp))
		giveUpIfNoCode(on: made, after: 10, message: "The other Mac did not answer. Check that it shows \"Now go to your other Mac\". If it does, allow Mousey under System Settings, Privacy & Security, Local Network, and allow incoming connections if its firewall asks.")
	}

	/// A connection that never reaches a code is either a stranger holding the only slot, or a network problem.
	private func giveUpIfNoCode(on made: PairingChannel, after seconds: Double, message: String?) {
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak made] in
			guard let self, let made, self.channel === made, self.pairingPhase == nil else { return }
			made.cancel()
			self.channel = nil
			self.pairingPeer = nil
			if let message { self.pairingMessage = message }
		}
	}

	private func answer(_ connection: NWConnection) {
		// One conversation at a time. Anyone can knock, and only a matching code on both screens lets them in.
		guard channel == nil, gate.allow(now: Date()) else { return connection.cancel() }
		let made = makeChannel(.responder)
		channel = made
		made.attach(connection)
		giveUpIfNoCode(on: made, after: 5, message: nil)
		if gate.isExhausted { stopListeningForPairing() }
	}

	private func stopListeningForPairing() {
		pairingListener?.stop()
		pairingListener = nil
		pairingStopped = true
	}

	private func makeChannel(_ pairingRole: Pairing.Role) -> PairingChannel {
		PairingChannel(role: pairingRole, id: Settings.localID, name: localName, onPhase: { [weak self] in self?.pairingChanged($0) }, onDisconnect: { [weak self] in
			guard let self, self.channel != nil else { return }
			if case .paired = self.pairingPhase { return }
			let wasComparing = self.pairingPhase != nil
			self.channel = nil
			self.pairingPhase = nil
			self.pairingPeer = nil
			// A stranger leaving is nothing to report on the controlled Mac.
			if wasComparing || pairingRole == .initiator { self.pairingMessage = "The connection to the other Mac ended. Try again." }
			if self.gate.isExhausted { self.stopListeningForPairing() }
		})
	}

	private func pairingChanged(_ phase: Pairing.Phase) {
		switch phase {
		case .exchanging:
			break
		case .comparing:
			pairingPhase = phase
		case .failed(let failure):
			pairingPhase = nil
			channel?.close()
			channel = nil
			pairingPeer = nil
			address = Settings.address
			if gate.isExhausted { stopListeningForPairing() }
			switch failure {
			case .rejected: pairingMessage = "The codes were not confirmed, so the Macs were not paired."
			case .expired: pairingMessage = "The code expired, so the Macs were not paired. Try again."
			default: pairingMessage = "Pairing stopped because something looked wrong. Try again, and check that the code matches on both Macs."
			}
		case .paired(let peer):
			pairingPhase = phase
			finishPairing(peer)
		}
	}

	func confirmCode(match: Bool) { channel?.confirm(match: match) }

	private func finishPairing(_ peer: PairedPeer) {
		guard keys.save(peer.key) else {
			pairingPhase = nil
			channel?.close()
			channel = nil
			pairingPeer = nil
			pairingMessage = "macOS would not store the pairing in the Keychain. Open Keychain Access, check that the login keychain is unlocked, and try again."
			return
		}
		Settings.peerID = peer.id
		Settings.peerName = peer.name
		Settings.address = role == .controller ? address : nil
		peerName = peer.name
		isPaired = true
		leavePairing()
		startEngine()
		advance()
	}

	func forgetPairing(keepingStep: Bool = false) {
		stopEngine()
		leavePairing()
		keys.delete()
		isPaired = false
		// Turning this on was a decision about that Mac, and it does not carry over to the next one.
		Settings.clipboardSharing = false
		clipboardOn = false
		Settings.peerID = nil
		Settings.peerName = nil
		Settings.address = nil
		peerName = nil
		address = nil
		pairingPhase = nil
		if !keepingStep { restartTutorial() }
		refreshStatus()
	}

	// MARK: Engines

	private func startEngine() {
		guard controller == nil, target == nil, let id = Settings.peerID, let key = keys.load(), let role else { return }
		Log.write("role \(role.rawValue), peer \(Settings.peerName ?? "unnamed"), edge \(edgeWord), Accessibility \(AXIsProcessTrusted())")
		switch role {
		case .controller:
			controller = ControllerEngine(peer: LinkPeer(id: id, key: key, address: Settings.address), edge: edge,
				onReport: { [weak self] in self?.received($0) }, onSecureInput: { [weak self] in self?.secureInput($0) })
		case .target:
			target = TargetEngine(key: key, serviceName: Settings.localID, onReport: { [weak self] in self?.received($0) })
		}
		startClipboard()
		if !AXIsProcessTrusted(), step == .done, !Settings.askedForAccessibility { requestAccessibility() }
	}

	func setClipboardSharing(_ on: Bool) {
		Settings.clipboardSharing = on
		clipboardOn = on
		stopClipboard()
		startClipboard()
	}

	private func startClipboard() {
		guard clipboardOn, ClipboardSync.current == nil, let id = Settings.peerID, let key = keys.load(), let role else { return }
		let peer: ClipboardSync.Peer = role == .controller ? .connect(peerID: id, address: Settings.address) : .listen(serviceName: Settings.localID)
		ClipboardSync.current = ClipboardSync(linkKey: key, peer: peer, onConnected: { [weak self] in self?.clipboardConnected = $0 })
	}

	private func stopClipboard() {
		ClipboardSync.current?.stop()
		ClipboardSync.current = nil
		clipboardConnected = false
	}

	private func stopEngine() {
		stopClipboard()
		controller?.terminate(.disabled)
		controller = nil
		target?.stop()
		target = nil
		controllerReport = nil
		targetReport = nil
	}

	private func restartEngine() {
		stopEngine()
		startEngine()
		refreshStatus()
	}

	private func received(_ report: ControllerReport) {
		controllerReport = report
		if report.core.isRemote { crossed = true }
		if crossed, !report.core.isRemote {
			cameBack = true
			if report.core.lastReturn == .panicChord { usedWayOut = true }
		}
		refreshStatus()
	}

	private func received(_ report: TargetReport) {
		targetReport = report
		controlledNow = report.core.controlled
		if report.core.controlled { wasControlled = true }
		refreshStatus()
	}

	// MARK: Status

	private func refreshStatus() {
		let next = currentStatus()
		if next != status { status = next }
	}

	private func currentStatus() -> AppStatus {
		guard let role, step != .welcome || isPaired else { return AppStatus(text: "Finish setting up Mousey") }
		guard isPaired else { return AppStatus(text: "Pair with your other Mac to start") }
		let name = peerName ?? "the other Mac"
		if !trusted { return AppStatus(text: "Allow Accessibility for Mousey", problem: true, fix: .accessibility) }
		switch role {
		case .target:
			guard let t = targetReport else { return AppStatus(text: "Starting") }
			if !t.bound { return AppStatus(text: "This Mac could not open its network port", problem: true) }
			if !t.canInject { return AppStatus(text: "macOS is refusing input. Turn Mousey off and on in Accessibility", problem: true, fix: .accessibility) }
			if t.networkDenied { return AppStatus(text: "Allow Mousey in Local Network settings", problem: true, fix: .localNetwork) }
			if t.versionMismatch { return AppStatus(text: "Update Mousey so both Macs run the same version", problem: true) }
			if !t.core.controllerSeen { return AppStatus(text: "Waiting for \(name)") }
			return AppStatus(text: t.core.controlled ? "Controlled by \(name)" : "Ready for \(name)", active: t.core.controlled)
		case .controller:
			guard let c = controllerReport else { return AppStatus(text: "Starting") }
			if c.otherVersion != nil { return AppStatus(text: "Update Mousey so both Macs run the same version", problem: true) }
			if c.networkDenied { return AppStatus(text: "Allow Mousey in Local Network settings", problem: true, fix: .localNetwork) }
			if !c.core.targetOnline { return AppStatus(text: "Cannot reach \(name). Open Mousey there, on the same network. See Help if it was forgotten", problem: true) }
			if !c.core.targetCanInject { return AppStatus(text: "\(name) needs Accessibility for Mousey", problem: true) }
			if c.core.lastReturn == .secureInput, !c.core.isRemote, IsSecureEventInputEnabled() {
				return AppStatus(text: "A password field on this Mac is blocking the keyboard", problem: true)
			}
			if c.core.isRemote { return AppStatus(text: "Controlling \(name)", active: true) }
			return AppStatus(text: "Push through the \(edgeWord) edge to control \(name)")
		}
	}

	// MARK: Duties

	private func observe() {
		let center = NSWorkspace.shared.notificationCenter
		let faults: [(Notification.Name, ReturnReason)] = [
			(NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.screensDidSleepNotification, .sleep),
			(NSWorkspace.sessionDidResignActiveNotification, .sessionChanged),
		]
		for (name, reason) in faults {
			center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.controller?.fault(reason) }
		}
		for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
			DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
				self?.controller?.setLocked(locked)
			}
		}
		for sig in [SIGINT, SIGTERM] {
			signal(sig, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
			source.setEventHandler { [weak self] in
				self?.stopEngine()
				exit(0)
			}
			source.resume()
			signalSources.append(source)
		}
	}

	/// The taps and the cursor state end with the process, so a stalled engine while remote is ended, not waited for.
	private func watchdog() {
		guard let controller, controller.capturing.pointee else { return lastBeatChange = Date() }
		let beat = controller.heartbeat.pointee
		if beat != lastBeat {
			lastBeat = beat
			lastBeatChange = Date()
		} else if Date().timeIntervalSince(lastBeatChange) > 2 {
			_exit(70)
		}
	}

	private func poll() {
		let installed = FileManager.default.fileExists(atPath: Lease.socketPath)
		if installed != helperInstalled { helperInstalled = installed }
		let now = AXIsProcessTrusted()
		guard now != trusted else { return }
		trusted = now
		// Turned off: a fresh process holds no consuming tap and shows the warning. The old one may be part of an input hang.
		// Turned on: a process started before the grant keeps reading false from the posting check (measured).
		if !now || !CGPreflightPostEventAccess() { return relaunch() }
		controller?.permissionGranted()
		if step == .accessibility { advance() }
		refreshStatus()
	}

	private func relaunch() {
		Log.write("Accessibility changed to \(trusted), relaunching")
		if trusted, step == .accessibility {
			let sequence = OnboardingStep.sequence(for: role)
			if let index = sequence.firstIndex(of: .accessibility) { Settings.onboardingStep = sequence[index + 1].rawValue }
		}
		// Process exit frees every tap, so a wedged stop or open must not keep this process alive.
		DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _exit(71) }
		stopEngine()
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.createsNewApplicationInstance = true
		NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
			if let error { Log.write("relaunch failed: \(error)") }
			_exit(error == nil ? 0 : 71)
		}
	}

	private func secureInput(_ capturing: Bool) {
		if capturing {
			focusToRestore.secureInputSeen(frontmost: NSWorkspace.shared.frontmostApplication)
			NSApp.activate(ignoringOtherApps: true)
		} else {
			focusToRestore.captureEnded()?.activate(options: [])
		}
	}

	private func openPane(_ url: String) {
		if let url = URL(string: url) { NSWorkspace.shared.open(url) }
	}

	// MARK: Wi-Fi smoothing

	func installHelper(thenAdvance: Bool = false) {
		helperBusy = true
		helperMessage = nil
		HelperInstaller.install { [weak self] message in
			guard let self else { return }
			helperBusy = false
			helperMessage = message
			poll()
			if message == nil, thenAdvance { advance() }
		}
	}

	func removeHelper() {
		helperBusy = true
		helperMessage = nil
		HelperInstaller.remove { [weak self] message in
			self?.helperBusy = false
			self?.helperMessage = message
			self?.poll()
		}
	}

	#if DEBUG
	/// `--render-screens` only: puts the model in a state to draw, with nothing started.
	func preview(step: OnboardingStep, role: Role?, phase: Pairing.Phase? = nil, nearby: [PairingBrowser.Found] = [], peer: String? = nil, crossed: Bool = false, cameBack: Bool = false, paired: Bool = false, status: AppStatus? = nil, clipboard: Bool = false, smooth: Bool = false, update: String? = nil) {
		self.step = step
		updateVersion = update
		isPaired = paired
		if let status { self.status = status }
		clipboardOn = clipboard
		clipboardConnected = clipboard
		helperInstalled = smooth
		self.role = role
		pairingPhase = phase
		self.nearby = nearby
		peerName = peer
		self.crossed = crossed
		self.cameBack = cameBack
		usedWayOut = cameBack
		wasControlled = cameBack
		edge = .left
	}
	#endif

	// MARK: Other

	var openAtLogin: Bool {
		get {
			guard #available(macOS 13, *) else { return false }
			return SMAppService.mainApp.status == .enabled
		}
		set {
			guard #available(macOS 13, *) else { return }
			objectWillChange.send()
			if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
		}
	}
}

extension AppModel {
	private var runningVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
	var checksForUpdates: Bool { updates.enabled }

	private func showUpdate() { updateVersion = runningVersion.flatMap(updates.notice(current:)) }

	private func checkForUpdate() {
		guard runningVersion != nil, updates.claimDailyCheck(now: Date()) else { return }
		UpdateCheck.latestTag { [weak self] tag in
			if let tag { self?.updates.record(tag: tag) }
		}
	}

	func setCheckingForUpdates(_ on: Bool) {
		objectWillChange.send()
		updates.enabled = on
		checkForUpdate()
	}

	func openReleasePage() { NSWorkspace.shared.open(UpdateCheck.releasePage) }
}
