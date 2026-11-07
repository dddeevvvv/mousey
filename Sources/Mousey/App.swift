import AppKit
import Combine
import MouseyCore
import SwiftUI

func runApp() -> Never {
	let app = NSApplication.shared
	app.setActivationPolicy(.accessory)
	let delegate = AppDelegate()
	app.delegate = delegate
	app.run()
	exit(0)
}

func withUpdateDot(_ symbol: NSImage) -> NSImage {
	let image = NSImage(size: symbol.size, flipped: false) { rect in
		symbol.draw(in: rect)
		NSColor.black.setFill()
		NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
		return true
	}
	image.isTemplate = true
	image.accessibilityDescription = symbol.accessibilityDescription
	return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
	private let model = AppModel()
	private var statusItem: NSStatusItem!
	private let menu = NSMenu()
	private var tutorial: NSWindow?
	private var settings: NSWindow?
	private var help: NSWindow?
	private var observations: [AnyCancellable] = []

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		menu.delegate = self
		statusItem.menu = menu
		model.start()
		observations = [
			model.$status.sink { [weak self] in self?.render($0, update: self?.model.updateVersion) },
			model.$updateVersion.sink { [weak self] in
				guard let self else { return }
				self.render(self.model.status, update: $0)
			},
			// A code on the screen needs a person, and so does a tutorial started from Settings.
			model.$pairingPhase.sink { [weak self] phase in if phase != nil { self?.showTutorial() } },
			model.$step.dropFirst().sink { [weak self] step in if step == .welcome { self?.showTutorial() } },
		]
		render(model.status, update: model.updateVersion)
		if model.step != .done { showTutorial() }
	}

	func applicationWillTerminate(_ notification: Notification) { model.terminate() }

	/// The Finder opening a running app means the person is looking for it.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
		if !hasVisibleWindows { model.step == .done ? showSettings() : showTutorial() }
		return false
	}

	private func render(_ status: AppStatus, update: String?) {
		let symbol = status.problem ? "exclamationmark.triangle" : status.active ? "cursorarrow.rays" : "cursorarrow"
		let note = update.map { ". Version \($0) is available" } ?? ""
		if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mousey: \(status.text)\(note)") {
			statusItem.button?.image = update == nil ? image : withUpdateDot(image)
			statusItem.button?.title = ""
		} else {
			statusItem.button?.image = nil
			statusItem.button?.title = status.problem ? "M!" : "M"
		}
		statusItem.button?.toolTip = status.text + note
	}

	func menuWillOpen(_ menu: NSMenu) {
		menu.removeAllItems()
		let line = NSMenuItem(title: model.status.text, action: model.status.fix == .none ? nil : #selector(fixStatus), keyEquivalent: "")
		line.target = self
		menu.addItem(line)
		menu.addItem(.separator())
		if let version = model.updateVersion { add("Get Version \(version)…", #selector(openReleasePage)) }
		if model.step != .done { add("Continue Setup…", #selector(openTutorial)) }
		add("Settings…", #selector(openSettings), key: ",")
		add("Help", #selector(openHelp))
		add("Show Tutorial Again", #selector(replayTutorial))
		menu.addItem(.separator())
		add("Quit Mousey", #selector(quit), key: "q")
	}

	private func add(_ title: String, _ action: Selector, key: String = "") {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.target = self
		menu.addItem(item)
	}

	@objc private func fixStatus() {
		if model.status.fix == .accessibility { model.requestAccessibility() }
		if model.status.fix == .localNetwork { model.openLocalNetworkPane() }
	}
	@objc private func openReleasePage() { model.openReleasePage() }
	@objc private func openTutorial() { showTutorial() }
	@objc private func openSettings() { showSettings() }
	@objc private func openHelp() { show(&help, title: "Mousey Help", size: NSSize(width: 560, height: 560), view: HelpView()) }
	@objc private func quit() { NSApp.terminate(nil) }

	@objc private func replayTutorial() {
		model.restartTutorial()
		showTutorial()
	}

	private func showTutorial() {
		show(&tutorial, title: "Mousey", size: Ink.window, view: OnboardingView(onFinish: { [weak self] in self?.tutorial?.close() }).environmentObject(model))
	}

	private func showSettings() {
		// Its height depends on the role, which the tutorial can change, so it is built fresh each time it opens.
		if settings?.isVisible != true { settings = nil }
		show(&settings, title: "Mousey Settings", size: NSSize(width: 480, height: SettingsView.height(for: model.role, paired: model.isPaired)), view: SettingsView().environmentObject(model))
	}

	private func show<V: View>(_ slot: inout NSWindow?, title: String, size: NSSize, view: V) {
		if slot == nil {
			let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
			window.title = title
			// The page runs to the edge of the window, so the window has no bar of its own colour.
			window.titleVisibility = .hidden
			window.titlebarAppearsTransparent = true
			window.styleMask.insert(.fullSizeContentView)
			window.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white }
			window.isReleasedWhenClosed = false
			window.contentView = NSHostingView(rootView: view.accentColor(Ink.ink))
			window.center()
			window.delegate = self
			slot = window
		}
		// A window of a menu bar app needs a Dock presence to come forward and to be found again.
		NSApp.setActivationPolicy(.regular)
		slot?.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func windowWillClose(_ notification: Notification) {
		let closing = notification.object as? NSWindow
		if [tutorial, settings, help].compactMap({ $0 }).allSatisfy({ $0 === closing || !$0.isVisible }) {
			NSApp.setActivationPolicy(.accessory)
		}
	}
}
