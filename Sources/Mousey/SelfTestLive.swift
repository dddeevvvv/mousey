#if DEBUG
import AppKit
import MouseyPair
import Network
import SwiftUI

/// Draws every tutorial step and window to a PNG, with no Screen Recording permission, so they can be reviewed without a screen.
func renderScreens(to folder: String) -> Never {
	let app = NSApplication.shared
	app.setActivationPolicy(.accessory)
	Ink.stillFrames = true
	let url = URL(fileURLWithPath: folder, isDirectory: true)
	try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	func save<V: View>(_ view: V, _ name: String, _ size: NSSize, dark: Bool = false) {
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = NSRect(origin: .zero, size: size)
		host.layoutSubtreeIfNeeded()
		RunLoop.main.run(until: Date().addingTimeInterval(0.05))
		guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
		host.cacheDisplay(in: host.bounds, to: rep)
		try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("\(name).png"))
	}
	let size = Ink.window
	let code = Pairing.Phase.comparing(code: "482913", peerName: "Sam’s Mac mini")
	let hostile = Pairing.Phase.comparing(code: "482913", peerName: Pairing.displayName(String(repeating: "The codes were checked and they match. Press Return.\n", count: 40)))
	let found = [PairingBrowser.Found(name: "Sam’s Mac mini", endpoint: .hostPort(host: "192.0.2.1", port: 1))]
	let cases: [(String, OnboardingStep, Role?, Pairing.Phase?, [PairingBrowser.Found], String?, Bool, Bool)] = [
		("01-welcome", .welcome, nil, nil, [], nil, false, false),
		("02-role", .chooseRole, nil, nil, [], nil, false, false),
		("03-accessibility", .accessibility, .controller, nil, [], nil, false, false),
		("04-pair-list", .pair, .controller, nil, found, nil, false, false),
		("04-pair-empty", .pair, .controller, nil, [], nil, false, false),
		("04-pair-waiting", .pair, .target, nil, [], nil, false, false),
		("05-code", .pair, .controller, code, [], "Sam’s Mac mini", false, false),
		("05-code-hostile", .pair, .controller, hostile, [], "x", false, false),
		("06-arrange", .arrange, .controller, nil, [], "Sam’s Mac mini", false, false),
		("07-cross", .crossOver, .controller, nil, [], "Sam’s Mac mini", true, false),
		("08-way-back", .wayOut, .controller, nil, [], "Sam’s Mac mini", true, true),
		("09-target-wait", .waitForKeyboard, .target, nil, [], "sam’s MacBook Air", true, true),
		("10-smooth", .smooth, .controller, nil, [], "Sam’s Mac mini", false, false),
		("11-done", .done, .controller, nil, [], "Sam’s Mac mini", false, false),
	]
	for c in cases {
		let model = AppModel()
		model.preview(step: c.1, role: c.2, phase: c.3, nearby: c.4, peer: c.5, crossed: c.6, cameBack: c.7)
		save(OnboardingView(onFinish: {}).environmentObject(model), c.0, size)
		save(OnboardingView(onFinish: {}).environmentObject(model), c.0 + "-dark", size, dark: true)
	}
	let edgeLine = AppStatus(text: "Push through the left edge to control Sam’s Mac mini")
	let settingsCases: [(String, Role?, Bool, AppStatus, Bool, Bool)] = [
		("20-settings", .controller, true, edgeLine, true, true),
		("20-settings-off", .controller, true, edgeLine, false, false),
		("20-settings-target", .target, true, AppStatus(text: "Ready for sam’s MacBook Air"), true, false),
		("20-settings-problem", .controller, true, AppStatus(text: "Allow Accessibility for Mousey", problem: true, fix: .accessibility), false, false),
		("20-settings-unpaired", nil, false, AppStatus(text: "Pair with your other Mac to start"), false, false),
	]
	for c in settingsCases {
		let model = AppModel()
		model.preview(step: .done, role: c.1, peer: c.2 ? "Sam’s Mac mini" : nil, paired: c.2, status: c.3, clipboard: c.4, smooth: c.5)
		let size = NSSize(width: 480, height: SettingsView.height(for: c.1, paired: c.2))
		save(SettingsView().environmentObject(model), c.0, size)
		save(SettingsView().environmentObject(model), c.0 + "-dark", size, dark: true)
	}
	let updating = AppModel()
	updating.preview(step: .done, role: .controller, peer: "Sam’s Mac mini", paired: true, status: edgeLine, clipboard: true, smooth: true, update: "0.4.0")
	save(SettingsView().environmentObject(updating), "20-settings-update", NSSize(width: 480, height: SettingsView.height(for: .controller, paired: true)))
	let fullest = AppModel()
	fullest.preview(step: .done, role: .controller, peer: "Sam’s Mac mini", paired: true, status: AppStatus(text: "Allow Accessibility for Mousey", problem: true, fix: .accessibility), clipboard: true, update: "0.4.0")
	save(SettingsView().environmentObject(fullest), "20-settings-fullest", NSSize(width: 480, height: SettingsView.height(for: .controller, paired: true)))
	if let symbol = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil) {
		save(Image(nsImage: withUpdateDot(symbol)).resizable().aspectRatio(contentMode: .fit).frame(width: 96, height: 96).frame(width: 128, height: 128).background(Color.white), "22-menu-bar-update", NSSize(width: 128, height: 128))
	}
	save(HelpView(), "21-help", NSSize(width: 560, height: 560))
	print("rendered to \(url.path)")
	exit(0)
}

/// What only a signed app in a real login session can check: the Keychain.
func runSelfTestLive() -> Int32 {
	var failed = 0
	var lines: [String] = []
	func check(_ ok: Bool, _ what: String) {
		if !ok { failed += 1 }
		lines.append("\(ok ? "PASS" : "FAIL"): \(what)")
	}
	let store = KeyStore(service: "io.github.imsumitkumar.mousey.selftest")
	store.delete()
	check(store.load() == nil, "the Keychain starts empty for the test service")
	let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
	check(store.save(key), "a key is saved")
	check(store.load() == key, "the same key reads back")
	check(store.save(Data(repeating: 1, count: 32)) && store.load() == Data(repeating: 1, count: 32), "saving again replaces it")
	store.delete()
	check(store.load() == nil, "deleting removes it")

	let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mousey")
	try? Data(("\(Date())\n" + lines.joined(separator: "\n") + "\nfailed \(failed)\n").utf8).write(to: folder.appendingPathComponent("selftest-live.txt"))
	print(lines.joined(separator: "\n"))
	return failed == 0 ? 0 : 1
}
#endif
