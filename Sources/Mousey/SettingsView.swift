import MouseyCore
import SwiftUI

/// One screen, no scrolling: who you're connected to, where they sit, and one switch per feature.
struct SettingsView: View {
	@EnvironmentObject var model: AppModel
	@State private var confirmForget = false

	static func height(for role: Role?, paired: Bool) -> CGFloat { role == .controller && paired ? 626 : 566 }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header.padding(.bottom, 18)

			Rectangle().fill(Ink.hair).frame(height: 1)
			if model.role == .controller, model.isPaired {
				positionRow
				Rectangle().fill(Ink.hair).frame(height: 1)
			}
			clipboardRow
			Rectangle().fill(Ink.hair).frame(height: 1)
			wifiRow
			if #available(macOS 13, *) {
				Rectangle().fill(Ink.hair).frame(height: 1)
				SettingRow(title: "Open at login", detail: nil, isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
			}
			Rectangle().fill(Ink.hair).frame(height: 1)
			updatesRow
			Rectangle().fill(Ink.hair).frame(height: 1)

			Spacer(minLength: 12)
			footer
		}
		.padding(.horizontal, 28)
		.padding(.top, 34)
		.padding(.bottom, 18)
		.frame(width: 480, height: Self.height(for: model.role, paired: model.isPaired))
		.background(Ink.page.ignoresSafeArea())
		.alert("Forget this Mac?", isPresented: $confirmForget) {
			Button("Cancel", role: .cancel) {}
			Button("Forget", role: .destructive) { model.forgetPairing() }
		} message: {
			Text("Click Forget on the other Mac too, then pair them again with a new code on both screens.")
		}
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .center, spacing: 12) {
				Text(model.isPaired ? (model.peerName ?? "Your other Mac") : "Not paired yet").font(Ink.headline(28)).foregroundColor(Ink.ink).lineLimit(1)
				Spacer(minLength: 0)
				if model.role == .controller, model.isPaired { EdgeGlyph(edge: model.edge) }
			}
			HStack(alignment: .firstTextBaseline, spacing: 7) {
				if model.status.problem { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)) }
				Text(model.status.text).font(.system(size: 14, weight: model.status.problem ? .semibold : .regular)).fixedSize(horizontal: false, vertical: true)
			}
			.foregroundColor(model.status.problem ? Ink.ink : Ink.muted)
			if model.status.fix == .accessibility { Button(model.askedForAccessibility ? "Open Accessibility settings" : "Allow access") { model.requestAccessibility() }.buttonStyle(KeyStyle(primary: true)).padding(.top, 8) }
			if model.status.fix == .localNetwork { Button("Open Local Network settings") { model.openLocalNetworkPane() }.buttonStyle(KeyStyle(primary: true)).padding(.top, 8) }
			if !model.isPaired, model.status.fix == .none { Button("Pair a Mac") { model.restartTutorial() }.buttonStyle(KeyStyle(primary: true)).padding(.top, 8) }
		}
	}

	private var positionRow: some View {
		HStack(alignment: .center, spacing: 12) {
			Text("Position").font(.system(size: 15, weight: .semibold)).foregroundColor(Ink.ink)
			Spacer(minLength: 0)
			EdgePicker(edge: Binding(get: { model.edge }, set: { model.setEdge($0) }))
		}
		.padding(.vertical, 11)
	}

	private var clipboardRow: some View {
		let detail: String
		if !model.clipboardOn {
			detail = "Copy on one Mac, cross, and paste on the other."
		} else if model.clipboardConnected {
			detail = "Working. Text, links, and images move as you cross. Items a password manager marks as secret stay here. Look before pasting into Terminal."
		} else {
			detail = "Not connected yet. Turn this on for the other Mac too."
		}
		return SettingRow(title: "Share clipboard", detail: detail, isOn: Binding(get: { model.clipboardOn }, set: { model.setClipboardSharing($0) }))
			.disabled(!model.isPaired)
			.opacity(model.isPaired ? 1 : 0.4)
	}

	private var wifiRow: some View {
		let detail: String
		if let message = model.helperMessage {
			detail = message
		} else if model.helperBusy {
			detail = "Waiting for your password."
		} else {
			detail = model.helperInstalled ? "Pausing AirDrop and Handoff's Wi-Fi while you work across Macs. Turn this on for the other Mac too." : "Stops pointer stutter by pausing AirDrop and Handoff's Wi-Fi while you work across Macs. Asks for your password once."
		}
		return SettingRow(title: "Smooth Wi-Fi", detail: detail, isOn: Binding(get: { model.helperInstalled }, set: { $0 ? model.installHelper() : model.removeHelper() }))
			.disabled(model.helperBusy)
	}

	private var updatesRow: some View {
		VStack(alignment: .leading, spacing: 0) {
			SettingRow(title: "Check for updates", detail: "Asks GitHub for the latest version number once a day. Nothing is downloaded or installed.", isOn: Binding(get: { model.checksForUpdates }, set: { model.setCheckingForUpdates($0) }))
			if let version = model.updateVersion {
				Button("Get version \(version)") { model.openReleasePage() }.buttonStyle(KeyStyle(primary: true)).padding(.bottom, 12)
			}
		}
	}

	private var footer: some View {
		HStack(spacing: 8) {
			Text("Stuck? ⌃ ⌥ ⌘ Esc brings you back.").font(Ink.small).foregroundColor(Ink.muted)
			Spacer()
			if model.isPaired { Button("Forget this Mac") { confirmForget = true }.buttonStyle(QuietStyle()) }
		}
	}
}

private struct SettingRow: View {
	let title: String
	let detail: String?
	@Binding var isOn: Bool

	var body: some View {
		HStack(alignment: .top, spacing: 16) {
			VStack(alignment: .leading, spacing: 3) {
				Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(Ink.ink)
				if let detail { Text(detail).font(Ink.small).foregroundColor(Ink.muted).fixedSize(horizontal: false, vertical: true) }
			}
			Spacer(minLength: 0)
			Toggle(isOn: $isOn) { EmptyView() }.toggleStyle(InkSwitch()).accessibilityLabel(title).padding(.top, 1)
		}
		.padding(.vertical, 12)
	}
}

struct HelpView: View {
	private let topics: [(String, String)] = [
		("Moving between Macs", "Push the pointer firmly through the edge you chose. It stops for a moment so you can reach things at the edge of the screen without crossing by accident. To come back, push through the far edge of the other Mac's screen."),
		("Getting back if something goes wrong", "Hold Control, Option, and Command, and press Esc. If the other Mac stops answering, control returns by itself within about a second."),
		("The pointer stutters", "Macs pause Wi-Fi about twice a second for AirDrop and Handoff. Turn on Smooth Wi-Fi in Settings on both Macs, or use Ethernet."),
		("The other Mac isn't found", "Open Mousey on it, and put both Macs on the same network. Guest networks often keep devices apart, so try your main network. You can also type the address it shows while pairing."),
		("The other Mac can't be reached after pairing", "Both Macs must hold the same pairing. If you clicked Forget on one, click Forget in Settings on the other too, and pair again."),
		("A Mac says it needs Accessibility", "Open System Settings, Privacy & Security, Accessibility, and turn on Mousey. If it's already on, turn it off and on again."),
		("macOS blocked the local network", "Open System Settings, Privacy & Security, Local Network, and turn on Mousey."),
		("Typing into a password field", "macOS hides keystrokes from every app while a password field on this Mac has focus. Mousey brings you back to this Mac, so what you type in that field can't go to the wrong one. Click out of the field and cross again."),
		("Copying between Macs", "Turn on clipboard sharing in Settings on both Macs. Copy on one, cross, and paste on the other. Text, links, and images move at the moment you cross, and not at any other time. Files don't move. Secrets marked by a password manager stay on their own Mac, and anything else you copied will travel, so look before pasting into Terminal."),
		("Updates", "When a new version is out, a dot appears on the menu bar icon and the menu offers it. Choosing it opens the download page in your browser. Mousey never downloads or installs anything by itself. To update, quit Mousey, replace it in Applications, and open it again, on both Macs. Update the controlled Mac first. If it has no keyboard, turn on Screen Sharing or attach a keyboard before you quit Mousey on it."),
		("Privacy", "Your input goes only to the Mac you paired with, encrypted with a key the two Macs agreed on. Mousey has no account, no servers, and no analytics. Once a day it asks GitHub for the latest version number, and you can turn that off in Settings. Its log records when things connect, and never what you type."),
		("License", "Mousey is free software under the GNU General Public License, version 3. It comes with no warranty. The source code and the license are at github.com/\(UpdateCheck.repository)."),
	]

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				Text("Help").font(Ink.headline(34)).foregroundColor(Ink.ink)
				ForEach(topics, id: \.0) { topic in
					VStack(alignment: .leading, spacing: 5) {
						Text(topic.0).font(.system(size: 15, weight: .bold)).foregroundColor(Ink.ink)
						Text(topic.1).font(Ink.body).foregroundColor(Ink.muted).fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			.padding(30)
		}
		.frame(width: 560, height: 560)
		.background(Ink.page.ignoresSafeArea())
	}
}
