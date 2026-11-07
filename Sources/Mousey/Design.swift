import AppKit
import MouseyCore
import SwiftUI

/// Black and white only. State shows through form: filled against outlined, pressed against raised.
enum Ink {
	static let page = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white })
	static let ink = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black })
	static let muted = ink.opacity(0.58)
	static let hair = ink.opacity(0.16)
	static let window = NSSize(width: 680, height: 500)
	/// `--render-screens` only: draw every moving thing at its resting pose.
	static var stillFrames = false

	static func headline(_ size: CGFloat = 42) -> Font { .system(size: size, weight: .heavy) }
	static let body = Font.system(size: 15)
	static let small = Font.system(size: 13)
}

/// The app's one character: the arrow everyone already knows.
struct Pointer: Shape {
	func path(in r: CGRect) -> Path {
		let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.86), (0.2, 0.67), (0.35, 1), (0.52, 0.93), (0.37, 0.61), (0.63, 0.61)]
		var p = Path()
		for (i, q) in points.enumerated() {
			let at = CGPoint(x: r.minX + q.0 * r.height * 0.8, y: r.minY + q.1 * r.height)
			if i == 0 { p.move(to: at) } else { p.addLine(to: at) }
		}
		p.closeSubpath()
		return p
	}
}

/// Visible on either colour, the way a real pointer is.
struct PointerMark: View {
	var size: CGFloat = 44
	var body: some View {
		Pointer().fill(Ink.page)
			.overlay(Pointer().stroke(Ink.ink, style: StrokeStyle(lineWidth: max(2, size / 22), lineJoin: .round)))
			.frame(width: size * 0.5, height: size)
	}
}

/// Runs its content on a clock, except with Reduce Motion or when drawn to an image, where it holds the last pose.
struct Moving<Content: View>: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var start: Date?
	@ViewBuilder var content: (Double?) -> Content

	var body: some View {
		Group {
			if let start, !reduceMotion, !Ink.stillFrames {
				TimelineView(.animation) { timeline in content(timeline.date.timeIntervalSince(start)) }
			} else {
				content(nil)
			}
		}
		.onAppear { start = Date() }
	}
}

struct Keycap: View {
	let text: String
	var width: CGFloat = 64
	var height: CGFloat = 64
	var size: CGFloat = 26
	var lit = false
	private let travel: CGFloat = 5

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: height * 0.2).fill(Ink.ink).offset(y: travel)
			RoundedRectangle(cornerRadius: height * 0.2).fill(lit ? Ink.ink : Ink.page)
				.overlay(RoundedRectangle(cornerRadius: height * 0.2).strokeBorder(Ink.ink, lineWidth: 2))
				.overlay(Text(text).font(.system(size: size, weight: .bold)).monospacedDigit().foregroundColor(lit ? Ink.page : Ink.ink))
				.offset(y: lit ? travel : 0)
		}
		.frame(width: width, height: height + travel)
		.animation(.spring(response: 0.18, dampingFraction: 0.6), value: lit)
	}
}

/// A button that is a key: it moves down when pressed, and the primary one is filled.
struct KeyStyle: ButtonStyle {
	var primary = false
	@Environment(\.isEnabled) private var enabled

	func makeBody(configuration: Configuration) -> some View {
		let travel: CGFloat = 4
		return configuration.label
			.font(.system(size: 14, weight: .semibold))
			.foregroundColor(primary ? Ink.page : Ink.ink)
			.padding(.horizontal, 18)
			.frame(height: 36)
			.background(RoundedRectangle(cornerRadius: 10).fill(primary ? Ink.ink : Ink.page))
			.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.ink, lineWidth: 2))
			.offset(y: configuration.isPressed ? travel : 0)
			.background(RoundedRectangle(cornerRadius: 10).fill(Ink.ink).offset(y: travel))
			.padding(.bottom, travel)
			.opacity(enabled ? 1 : 0.35)
			.contentShape(Rectangle())
			.animation(.spring(response: 0.15, dampingFraction: 0.65), value: configuration.isPressed)
	}
}

struct QuietStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label.font(.system(size: 14, weight: .medium)).foregroundColor(configuration.isPressed ? Ink.ink : Ink.muted).padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle())
	}
}

struct CheckRow: View {
	let done: Bool
	let text: String
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 11) {
			ZStack {
				Circle().stroke(Ink.ink, lineWidth: 1.5)
				if done {
					Circle().fill(Ink.ink)
					Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(Ink.page)
				}
			}
			.frame(width: 16, height: 16)
			.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
			Text(text).font(Ink.body).foregroundColor(Ink.ink).fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
		}
		.animation(.easeOut(duration: 0.15), value: done)
	}
}

/// macOS draws its own switch in the system's accent colour, which would be the only colour in the app.
struct InkSwitch: ToggleStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 10) {
			configuration.label.font(Ink.body).foregroundColor(Ink.ink)
			Button { configuration.isOn.toggle() } label: {
				ZStack(alignment: configuration.isOn ? .trailing : .leading) {
					RoundedRectangle(cornerRadius: 12, style: .circular).fill(configuration.isOn ? Ink.ink : Ink.page)
						.overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(Ink.ink, lineWidth: 1.5))
					Circle().fill(configuration.isOn ? Ink.page : Ink.ink).padding(4.5)
				}
				.frame(width: 42, height: 24)
				.contentShape(Rectangle())
				.animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isOn)
			}
			.buttonStyle(.plain)
			.accessibilityValue(configuration.isOn ? "On" : "Off")
		}
	}
}

/// The two screens at a glance, the way they sit on the desk.
struct EdgeGlyph: View {
	let edge: Edge
	var body: some View {
		let this = RoundedRectangle(cornerRadius: 3).fill(Ink.ink).frame(width: 28, height: 18)
		let other = RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.ink, lineWidth: 1.5).frame(width: 28, height: 18)
		Group {
			switch edge {
			case .left: HStack(spacing: 2) { other; this }
			case .right: HStack(spacing: 2) { this; other }
			case .top: VStack(spacing: 2) { other; this }
			case .bottom: VStack(spacing: 2) { this; other }
			}
		}
		.accessibilityHidden(true)
	}
}

/// Four choices in one control, so they read as one question and not four buttons.
struct EdgePicker: View {
	@Binding var edge: Edge
	private let choices: [(Edge, String)] = [(.left, "Left"), (.right, "Right"), (.top, "Above"), (.bottom, "Below")]

	var body: some View {
		HStack(spacing: 0) {
			ForEach(choices, id: \.1) { choice, name in
				Button { edge = choice } label: {
					Text(name).font(.system(size: 13, weight: .semibold))
						.foregroundColor(edge == choice ? Ink.page : Ink.ink)
						.frame(width: 60, height: 26)
						.background(RoundedRectangle(cornerRadius: 8, style: .circular).fill(edge == choice ? Ink.ink : Color.clear))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityAddTraits(edge == choice ? .isSelected : [])
			}
		}
		.padding(3)
		.overlay(RoundedRectangle(cornerRadius: 11, style: .circular).strokeBorder(Ink.ink, lineWidth: 1.5))
	}
}

/// The switch macOS shows in Settings, so the person recognizes it when they get there.
struct BigSwitch: View {
	let on: Bool
	var body: some View {
		ZStack(alignment: on ? .trailing : .leading) {
			RoundedRectangle(cornerRadius: 32, style: .circular).fill(on ? Ink.ink : Ink.page).overlay(RoundedRectangle(cornerRadius: 32, style: .circular).strokeBorder(Ink.ink, lineWidth: 3))
			Circle().fill(on ? Ink.page : Ink.ink).padding(8)
		}
		.frame(width: 116, height: 64)
		.animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
	}
}

/// Two screens as they stand on the desk, and where the pointer is right now.
struct DeskScene: View {
	let edge: Edge
	var onOther = false
	var pushing = false
	var thisLabel = "This Mac"
	var otherLabel = "Other Mac"
	var screen = CGSize(width: 210, height: 132)
	private let gap: CGFloat = 8

	private var otherOffset: CGSize {
		switch edge {
		case .left: return CGSize(width: -(screen.width + gap) / 2, height: 0)
		case .right: return CGSize(width: (screen.width + gap) / 2, height: 0)
		case .top: return CGSize(width: 0, height: -(screen.height + gap) / 2)
		case .bottom: return CGSize(width: 0, height: (screen.height + gap) / 2)
		}
	}

	private var outward: CGSize {
		let o = otherOffset
		return CGSize(width: o.width == 0 ? 0 : (o.width < 0 ? -1 : 1), height: o.height == 0 ? 0 : (o.height < 0 ? -1 : 1))
	}

	var body: some View {
		let o = otherOffset
		return ZStack {
			RoundedRectangle(cornerRadius: 10).fill(Ink.ink)
				.overlay(Text(thisLabel).font(Ink.small).foregroundColor(Ink.page).padding(10), alignment: .bottomLeading)
				.frame(width: screen.width, height: screen.height)
				.offset(x: -o.width, y: -o.height)
			RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.ink, lineWidth: 2)
				.overlay(Text(otherLabel).font(Ink.small).lineLimit(1).foregroundColor(Ink.ink).padding(10), alignment: .bottomLeading)
				.frame(width: screen.width, height: screen.height)
				.offset(x: o.width, y: o.height)
			Moving { time in
				let nudge = pushing ? CGFloat(time.map { max(0, sin($0 * 5)) } ?? 0.4) * 7 : 0
				PointerMark(size: 42).offset(
					x: onOther ? o.width : outward.width * (nudge - 16) + 8,
					y: onOther ? o.height : outward.height * (nudge - 16) + 2)
			}
			.animation(.spring(response: 0.42, dampingFraction: 0.72), value: onOther)
		}
		.frame(width: edge == .left || edge == .right ? screen.width * 2 + gap : screen.width,
			height: edge == .left || edge == .right ? screen.height : screen.height * 2 + gap)
		.accessibilityElement()
		.accessibilityLabel(onOther ? "The pointer is on the other Mac" : "The pointer is on this Mac")
	}
}

/// Rings around the pointer, for while this Mac looks or waits.
struct Rings: View {
	var body: some View {
		Moving { time in
			ZStack {
				ForEach(0..<3, id: \.self) { i in
					let phase = time.map { ($0 / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1) } ?? (Double(i) + 1) / 3
					Circle().stroke(Ink.ink, lineWidth: 1.5)
						.frame(width: 44 + 130 * phase, height: 44 + 130 * phase)
						.opacity(1 - phase)
				}
				PointerMark(size: 34).offset(x: 6, y: 2)
			}
		}
		.frame(height: 150)
		.accessibilityHidden(true)
	}
}

/// What Wi-Fi does to a moving pointer: a stall twice a second, or none.
struct StallLine: View {
	let smooth: Bool
	var body: some View {
		Moving { time in
			Canvas { context, size in
				var path = Path()
				let shift = (time ?? 0) * 70
				var x: CGFloat = 0
				var y = size.height / 2
				path.move(to: CGPoint(x: 0, y: y))
				while x <= size.width {
					let world = Double(x) + shift
					let held = !smooth && world.truncatingRemainder(dividingBy: 170) < 40
					if !held { y = size.height / 2 + sin(world / 16) * size.height * 0.36 }
					path.addLine(to: CGPoint(x: x, y: y))
					x += 2
				}
				context.stroke(path, with: .color(Ink.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
			}
		}
		.frame(height: 76)
		.accessibilityHidden(true)
	}
}

/// The pointer running the fast circle the whole product exists to keep smooth.
struct CircleLap: View {
	private let lap = 1.3, rest = 2.4, radius: CGFloat = 58

	var body: some View {
		Moving { time in
			Canvas { context, size in
				let center = CGPoint(x: size.width / 2, y: size.height / 2)
				func at(_ turn: Double) -> CGPoint {
					CGPoint(x: center.x + cos(turn * 2 * .pi - .pi / 2) * radius, y: center.y + sin(turn * 2 * .pi - .pi / 2) * radius)
				}
				let cycle = (time ?? (lap + rest)).truncatingRemainder(dividingBy: lap + rest)
				let run = time == nil ? 1 : min(cycle / lap, 1)
				let eased = run * run * (3 - 2 * run)
				let steps = 90
				for i in 0..<steps where Double(i) / Double(steps) < eased {
					let turn = Double(i) / Double(steps)
					let fade = time == nil ? 1 : max(0, 1 - (eased - turn) * 1.3) * (cycle > lap ? max(0, 1 - (cycle - lap) / 0.8) : 1)
					context.fill(Path(ellipseIn: CGRect(x: at(turn).x - 2, y: at(turn).y - 2, width: 4, height: 4)), with: .color(Ink.ink.opacity(fade)))
				}
				let tip = at(eased)
				let rect = CGRect(x: tip.x, y: tip.y, width: 28, height: 36)
				context.fill(Pointer().path(in: rect), with: .color(Ink.page))
				context.stroke(Pointer().path(in: rect), with: .color(Ink.ink), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
			}
		}
		.frame(width: 190, height: 170)
		.accessibilityHidden(true)
	}
}
