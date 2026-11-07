import AppKit
import IOKit.ps
import MouseyCore
import MouseyPair
import SwiftUI

/// A tutorial that teaches by doing: each step checks the real result, then lets the person go on.
struct OnboardingView: View {
	@EnvironmentObject var model: AppModel
	var onFinish: () -> Void

	var body: some View {
		Group {
			switch model.step {
			case .welcome: WelcomeStep()
			case .chooseRole: ChooseRoleStep()
			case .accessibility: AccessibilityStep()
			case .pair: PairStep()
			case .arrange: ArrangeStep()
			case .crossOver: CrossOverStep()
			case .wayOut: WayOutStep()
			case .waitForKeyboard: WaitForKeyboardStep()
			case .smooth: SmoothStep()
			case .done: DoneStep(onFinish: onFinish)
			}
		}
		.frame(width: Ink.window.width, height: Ink.window.height)
		.background(Ink.page.ignoresSafeArea())
	}
}

/// How far along, drawn as the pointer's trip from this Mac to the other one.
private struct Journey: View {
	@EnvironmentObject var model: AppModel

	var body: some View {
		let steps = OnboardingStep.sequence(for: model.role)
		let index = steps.firstIndex(of: model.step) ?? 0
		let progress = CGFloat(index) / CGFloat(max(steps.count - 1, 1))
		return HStack(spacing: 5) {
			RoundedRectangle(cornerRadius: 2).fill(Ink.ink).frame(width: 14, height: 10)
			ZStack(alignment: .leading) {
				Rectangle().fill(Ink.hair).frame(width: 96, height: 2)
				Rectangle().fill(Ink.ink).frame(width: 96 * progress, height: 2)
				Pointer().fill(Ink.ink).frame(width: 9, height: 12).offset(x: 96 * progress - 3, y: 1)
			}
			.frame(width: 96, height: 14)
			RoundedRectangle(cornerRadius: 2).stroke(Ink.ink, lineWidth: 1.5).frame(width: 14, height: 10)
		}
		.animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
		.accessibilityElement()
		.accessibilityLabel("Step \(index + 1) of \(steps.count)")
	}
}

/// One frame for every step: words top left, the thing itself in the middle, the way forward bottom right.
private struct Stage<Content: View, Actions: View>: View {
	@EnvironmentObject var model: AppModel
	let title: String
	var line: String?
	var back = true
	@ViewBuilder var content: Content
	@ViewBuilder var actions: Actions

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(title).font(Ink.headline()).foregroundColor(Ink.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
			if let line {
				Text(line).font(Ink.body).foregroundColor(Ink.muted).lineLimit(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading).padding(.top, 8)
			}
			Spacer(minLength: 8)
			content.frame(maxWidth: .infinity)
			Spacer(minLength: 8)
			HStack(spacing: 8) {
				Journey()
				Spacer()
				if back { Button("Back") { model.goBack() }.buttonStyle(QuietStyle()) }
				actions
			}
		}
		.padding(.horizontal, 36)
		.padding(.top, 34)
		.padding(.bottom, 22)
	}
}

private struct Note: View {
	let text: String
	var body: some View {
		Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(Ink.ink).fixedSize(horizontal: false, vertical: true)
	}
}

// MARK: Steps

private struct WelcomeStep: View {
	@EnvironmentObject var model: AppModel
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var arrived = false

	var body: some View {
		ZStack(alignment: .topLeading) {
			// The one big entrance. Everything after this stays quiet.
			Pointer().fill(Ink.ink)
				.frame(width: 340, height: 425)
				.offset(x: 396, y: arrived || Ink.stillFrames ? 128 : 540)
				.animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.72), value: arrived)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 0) {
				Text("One keyboard.\nTwo Macs.").font(Ink.headline(50)).foregroundColor(Ink.ink).lineSpacing(-2)
				Spacer()
				Text("Push the pointer off this screen.\nIt keeps going on the other one.").font(.system(size: 16)).foregroundColor(Ink.ink).lineSpacing(2)
				Text("Open Mousey on both Macs, on the same network. If the other Mac has no keyboard, use Screen Sharing for the first few clicks.").font(Ink.small).foregroundColor(Ink.muted).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
				Button("Get started") { model.advance() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction).padding(.top, 18)
			}
			.padding(.horizontal, 36)
			.padding(.top, 34)
			.padding(.bottom, 22)
			.frame(maxHeight: .infinity, alignment: .leading)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.clipped()
		.onAppear { arrived = true }
	}
}

/// A battery is the honest test. Newer laptops no longer have "MacBook" in their model name.
private let isLaptop: Bool = {
	guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return false }
	return CFArrayGetCount(list) > 0
}()

private struct ChooseRoleStep: View {
	@EnvironmentObject var model: AppModel
	var body: some View {
		Stage(title: "Which Mac is this?", line: "Choose one of each, one on each Mac.") {
			HStack(spacing: 16) {
				RoleKey(symbol: "keyboard", title: "It has the keyboard", text: "Its keyboard and trackpad will also drive the other Mac.", suggested: isLaptop) { model.choose(role: .controller) }
				RoleKey(symbol: "display", title: "It follows", text: "It takes its input from the other Mac's keyboard and trackpad.", suggested: !isLaptop) { model.choose(role: .target) }
			}
		} actions: {
			EmptyView()
		}
	}
}

private struct RoleKey: View {
	let symbol: String
	let title: String
	let text: String
	let suggested: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			VStack(alignment: .leading, spacing: 6) {
				Image(systemName: symbol).font(.system(size: 34, weight: .regular)).frame(height: 54, alignment: .leading)
				Text(title).font(.system(size: 19, weight: .bold))
				Text(text).font(Ink.small).opacity(0.75).fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 0)
				Text(suggested ? "Most likely this one" : " ").font(.system(size: 12, weight: .semibold))
			}
			.padding(18)
			.frame(maxWidth: .infinity, alignment: .leading)
			.frame(height: 200)
		}
		.buttonStyle(CardKeyStyle(filled: suggested))
	}
}

private struct CardKeyStyle: ButtonStyle {
	let filled: Bool
	func makeBody(configuration: Configuration) -> some View {
		let travel: CGFloat = 6
		return configuration.label
			.foregroundColor(filled ? Ink.page : Ink.ink)
			.background(RoundedRectangle(cornerRadius: 16).fill(filled ? Ink.ink : Ink.page))
			.overlay(RoundedRectangle(cornerRadius: 16).stroke(Ink.ink, lineWidth: 2))
			.offset(y: configuration.isPressed ? travel : 0)
			.background(RoundedRectangle(cornerRadius: 16).fill(Ink.ink).offset(y: travel))
			.padding(.bottom, travel)
			.contentShape(Rectangle())
			.animation(.spring(response: 0.15, dampingFraction: 0.65), value: configuration.isPressed)
	}
}

private struct AccessibilityStep: View {
	@EnvironmentObject var model: AppModel
	var body: some View {
		Stage(title: "Flip one switch.", line: "macOS asks this of every app that reads or sends keyboard and mouse input. Your input goes only to the Mac you pair with.") {
			VStack(spacing: 20) {
				ZStack(alignment: .bottomTrailing) {
					BigSwitch(on: model.trusted)
					PointerMark(size: 34).offset(x: 6, y: 20)
				}
				Text(model.askedForAccessibility
					? "In System Settings, turn on Mousey. If it isn't listed, click + and choose it from Applications. This screen moves on by itself, and the app may restart once."
					: "macOS asks next. Choose to open System Settings, then turn on Mousey. This screen moves on by itself, and the app may restart once.").font(Ink.small).foregroundColor(Ink.muted).multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
			}
		} actions: {
			Button(model.askedForAccessibility ? "Open System Settings" : "Allow access") { model.requestAccessibility() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
		}
	}
}

private struct PairStep: View {
	@EnvironmentObject var model: AppModel
	@State private var typed = ""

	var body: some View {
		switch model.pairingPhase {
		case .comparing(let code, let peer):
			// `.id` starts fresh for a new code, so an answer to the last attempt cannot carry over.
			CompareCode(code: code, peer: peer).id(code)
		default:
			if model.isPaired { paired } else if model.pairingStopped { stopped } else if model.role == .target { waiting } else { choosing }
		}
	}

	private var stopped: some View {
		Stage(title: "Pairing paused.", line: "Too many connection attempts reached this Mac without finishing, so it stopped listening. If they weren't yours, someone else on this network made them. Use a network you trust.") {
			Image(systemName: "hand.raised").font(.system(size: 54)).foregroundColor(Ink.ink)
		} actions: {
			Button("Try again") { model.retryPairing() }.buttonStyle(KeyStyle(primary: true))
		}
	}

	private var paired: some View {
		Stage(title: "Paired.", line: "These two Macs now know each other, and everything between them is encrypted. Nobody else's Mac can connect.") {
			DeskScene(edge: model.edge, thisLabel: "This Mac", otherLabel: model.peerName ?? "Other Mac")
		} actions: {
			Button("Pair again") { model.forgetPairing(keepingStep: true); model.retryPairing() }.buttonStyle(KeyStyle())
			Button("Continue") { model.advance() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
		}
	}

	private var waiting: some View {
		Stage(title: "Now go to the other Mac.", line: "Choose \"It has the keyboard\" there, then pick \(Pairing.displayName(model.localName)).") {
			VStack(spacing: 10) {
				Rings()
				if let message = model.pairingMessage {
					Note(text: message).frame(maxWidth: 480)
				} else {
					Text("If macOS asks about the local network or incoming connections, click Allow.").font(Ink.small).foregroundColor(Ink.muted)
				}
				if !model.addresses.isEmpty {
					Text("Not showing up there? Type \(model.addresses.joined(separator: " or ")) instead.").font(Ink.small).foregroundColor(Ink.muted).multilineTextAlignment(.center).textSelection(.enabled)
				}
			}
		} actions: {
			EmptyView()
		}
	}

	private var choosing: some View {
		Stage(title: "Find your other Mac.", line: model.nearby.isEmpty ? "Open Mousey on it and choose \"It follows\". It appears here when it's ready." : nil) {
			VStack(spacing: 12) {
				if model.nearby.isEmpty {
					Rings()
					Text("A Mac paired before stays hidden until you click Forget in its Settings.").font(Ink.small).foregroundColor(Ink.muted)
				}
				ScrollView {
					VStack(spacing: 0) {
						ForEach(model.nearby) { mac in
							Button { model.pair(with: mac) } label: {
								HStack(spacing: 12) {
									Image(systemName: "display").font(.system(size: 18))
									Text(mac.name).font(.system(size: 17, weight: .semibold))
									Spacer()
									if model.pairingPeer == mac.name { ProgressView().scaleEffect(0.6).frame(height: 18) } else { Text("Pair").font(.system(size: 14, weight: .semibold)) }
								}
								.foregroundColor(Ink.ink)
								.padding(.vertical, 13)
								.overlay(Rectangle().fill(Ink.hair).frame(height: 1), alignment: .bottom)
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
						}
					}
				}
				.frame(maxHeight: model.nearby.isEmpty ? 0 : 150)
				if case .other(let why) = model.browseTrouble { Note(text: "Looking for Macs is having trouble: \(why)") }
				if model.browseTrouble == .localNetworkDenied {
					HStack {
						Note(text: "macOS is blocking Mousey from the local network.")
						Button("Open settings") { model.openLocalNetworkPane() }.buttonStyle(KeyStyle())
					}
				}
				if let message = model.pairingMessage { Note(text: message) }
				HStack(spacing: 8) {
					Text("Not listed?").font(Ink.small).foregroundColor(Ink.muted)
					TextField("Type the address it shows", text: $typed).textFieldStyle(.roundedBorder).frame(width: 190)
					Button("Connect") { model.pair(withAddress: typed) }.buttonStyle(KeyStyle()).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
				}
			}
		} actions: {
			EmptyView()
		}
	}
}

/// Yes is never the default button: the other side chooses the name on this screen, and one careless Return must not trust it.
private struct CompareCode: View {
	@EnvironmentObject var model: AppModel
	let code: String
	let peer: String
	@State private var answered = false

	var body: some View {
		Stage(title: "Same code on both?", line: "Say yes only if the other Mac shows exactly these digits. This Mac is being asked to trust: \(peer)", back: false) {
			VStack(spacing: 18) {
				HStack(spacing: 8) {
					ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
						Keycap(text: String(digit), width: 76, height: 86, size: 42).padding(.leading, index == 3 ? 18 : 0)
					}
				}
				Text(answered ? "Waiting for the other Mac" : " ").font(Ink.small).foregroundColor(Ink.muted)
			}
			.accessibilityElement()
			.accessibilityLabel("The code is \(code.map(String.init).joined(separator: " "))")
		} actions: {
			Button("No, stop") { model.confirmCode(match: false) }.buttonStyle(KeyStyle())
			Button("Yes, they match") { answered = true; model.confirmCode(match: true) }.buttonStyle(KeyStyle(primary: true)).disabled(answered)
		}
	}
}

private struct ArrangeStep: View {
	@EnvironmentObject var model: AppModel
	var body: some View {
		Stage(title: "Where's the other Mac?", line: "Drag its screen to where it really sits on your desk.") {
			ArrangeView()
		} actions: {
			Button("Continue") { model.advance() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
		}
	}
}

private struct CrossOverStep: View {
	@EnvironmentObject var model: AppModel
	var body: some View {
		Stage(title: "Now try it.") {
			VStack(spacing: 20) {
				DeskScene(edge: model.edge, onOther: model.crossed && !model.cameBack, pushing: !model.crossed, otherLabel: model.peerName ?? "Other Mac", screen: CGSize(width: 190, height: 118))
				VStack(spacing: 8) {
					CheckRow(done: model.crossed, text: "Push firmly through the \(model.edgeWord) edge of this screen.")
					CheckRow(done: model.cameBack, text: "Move around over there, then push back through the far edge.")
				}
				.frame(maxWidth: 470)
				if model.status.problem { Note(text: model.status.text) }
			}
		} actions: {
			if model.cameBack {
				Button("Continue") { model.advance() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
			} else {
				Button("Skip") { model.advance() }.buttonStyle(QuietStyle())
			}
		}
	}
}

private struct WayOutStep: View {
	@EnvironmentObject var model: AppModel
	@State private var held = Set<Int>()
	@State private var monitor: Any?
	private let keys: [(code: Int, label: String, width: CGFloat)] = [(59, "control", 116), (58, "option", 104), (55, "command", 128), (53, "esc", 74)]

	var body: some View {
		Stage(title: "Learn the way back.", line: "If you ever get stuck on the other Mac, these four keys always bring you home. Try holding them here.") {
			VStack(spacing: 22) {
				HStack(spacing: 8) {
					ForEach(keys, id: \.code) { key in
						Keycap(text: key.label, width: key.width, height: 62, size: 15, lit: held.contains(key.code))
					}
				}
				CheckRow(done: model.usedWayOut, text: "Now cross to the other Mac, hold all four, and watch the pointer come back.").frame(maxWidth: 480)
			}
		} actions: {
			if model.usedWayOut {
				Button("Continue") { model.advance() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
			} else {
				Button("Skip") { model.advance() }.buttonStyle(QuietStyle())
			}
		}
		.onAppear {
			monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
				var next = held
				let flags = event.modifierFlags
				for (code, flag) in [(59, NSEvent.ModifierFlags.control), (58, .option), (55, .command)] {
					if flags.contains(flag) { next.insert(code) } else { next.remove(code) }
				}
				if event.type == .keyDown, event.keyCode == 53 { next.insert(53) }
				if event.type == .keyUp, event.keyCode == 53 { next.remove(53) }
				held = next
				return event
			}
		}
		.onDisappear {
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
		}
	}
}

private struct WaitForKeyboardStep: View {
	@EnvironmentObject var model: AppModel
	var body: some View {
		Stage(title: "Watch this screen.", line: "Follow the steps on \(model.peerName ?? "the other Mac"). When its pointer crosses, this is where it lands.") {
			VStack(spacing: 16) {
				RoundedRectangle(cornerRadius: 12).stroke(Ink.ink, lineWidth: 2)
					.frame(width: 260, height: 150)
					.overlay(PointerMark(size: 46).opacity(model.controlledNow ? 1 : 0).scaleEffect(model.controlledNow ? 1 : 0.4).animation(.spring(response: 0.3, dampingFraction: 0.6), value: model.controlledNow))
				CheckRow(done: model.wasControlled, text: model.controlledNow ? "That's the other Mac's pointer. Push it back through the far edge." : "Waiting for the pointer to cross.").frame(maxWidth: 440)
				if model.status.problem { Note(text: model.status.text) }
			}
		} actions: {
			if model.wasControlled {
				Button("Continue") { model.advance() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
			} else {
				Button("Skip") { model.advance() }.buttonStyle(QuietStyle())
			}
		}
	}
}

private struct SmoothStep: View {
	@EnvironmentObject var model: AppModel
	var body: some View {
		Stage(title: "Smooth out the Wi-Fi.", line: "Macs pause Wi-Fi about twice a second for AirDrop and Handoff. Browsers hide it, but a pointer shows it. Mousey can stop those pauses while you use it, then turn them back on 30 seconds after you stop.") {
			VStack(spacing: 14) {
				StallLine(smooth: model.helperInstalled).frame(maxWidth: 480)
				Text(model.helperInstalled ? "Smoothing is on for this Mac. Turn it on for the other Mac too." : "macOS asks for your password once. Do this on both Macs. You can remove it in Settings.").font(Ink.small).foregroundColor(Ink.muted)
				if let message = model.helperMessage { Note(text: message) }
			}
		} actions: {
			if model.helperInstalled {
				Button("Continue") { model.advance() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
			} else {
				Button("Not now") { model.advance() }.buttonStyle(QuietStyle())
				Button(model.helperBusy ? "Waiting for password" : "Turn on") { model.installHelper(thenAdvance: true) }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(model.helperBusy)
			}
		}
	}
}

private struct DoneStep: View {
	@EnvironmentObject var model: AppModel
	var onFinish: () -> Void
	var body: some View {
		Stage(title: "That's it.", line: "Mousey stays in your menu bar. Its icon shows where you are.", back: false) {
			HStack(alignment: .center, spacing: 40) {
				CircleLap()
				VStack(alignment: .leading, spacing: 12) {
					Label("On this Mac", systemImage: "cursorarrow")
					Label("On the other Mac", systemImage: "cursorarrow.rays")
					Label("Needs you", systemImage: "exclamationmark.triangle")
					if #available(macOS 13, *) {
						Toggle("Open when I log in", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 })).toggleStyle(InkSwitch()).padding(.top, 6)
					}
					Text("Copy and paste across Macs is off. Turn it on in Settings.").font(Ink.small).foregroundColor(Ink.muted).fixedSize(horizontal: false, vertical: true).frame(width: 240, alignment: .leading)
				}
				.font(Ink.body)
				.foregroundColor(Ink.ink)
			}
		} actions: {
			Button("Finish") { onFinish() }.buttonStyle(KeyStyle(primary: true)).keyboardShortcut(.defaultAction)
		}
	}
}

/// Drag the other Mac's screen around this one. It snaps to the nearest side, because crossing happens at one edge.
struct ArrangeView: View {
	@EnvironmentObject var model: AppModel
	@State private var drag = CGSize.zero
	private let size = CGSize(width: 150, height: 94)

	private func offset(for edge: Edge) -> CGSize {
		switch edge {
		case .left: return CGSize(width: -size.width - 6, height: 0)
		case .right: return CGSize(width: size.width + 6, height: 0)
		case .top: return CGSize(width: 0, height: -size.height - 6)
		case .bottom: return CGSize(width: 0, height: size.height + 6)
		}
	}

	var body: some View {
		VStack(spacing: 18) {
			ZStack {
				RoundedRectangle(cornerRadius: 8).fill(Ink.ink)
					.overlay(Text("This Mac").font(Ink.small).foregroundColor(Ink.page))
					.frame(width: size.width, height: size.height)
				RoundedRectangle(cornerRadius: 8).fill(Ink.page)
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.ink, lineWidth: 2))
					.overlay(Text(model.peerName ?? "Other Mac").font(Ink.small).lineLimit(1).foregroundColor(Ink.ink).padding(6))
					.frame(width: size.width, height: size.height)
					.offset(x: offset(for: model.edge).width + drag.width, y: offset(for: model.edge).height + drag.height)
					.gesture(DragGesture().onChanged { drag = $0.translation }.onEnded { value in
						let base = offset(for: model.edge)
						let x = base.width + value.translation.width, y = base.height + value.translation.height
						let next: Edge = abs(x) / size.width > abs(y) / size.height ? (x < 0 ? .left : .right) : (y < 0 ? .top : .bottom)
						drag = .zero
						if next != model.edge { model.setEdge(next) }
					})
					.animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.edge)
					.animation(.interactiveSpring(), value: drag)
					.accessibilityLabel("The other Mac's screen, \(model.edgeWord) of this one")
			}
			.frame(height: 200)
			EdgePicker(edge: Binding(get: { model.edge }, set: { model.setEdge($0) }))
		}
	}
}
