// Draws the app icon: two screens, and a pointer crossing the gap between them.
import AppKit

func draw(_ size: CGFloat) -> Data {
	let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
	let ctx = NSGraphicsContext.current!.cgContext
	ctx.scaleBy(x: size / 1024, y: size / 1024)

	// Apple's grid: a 824-point rounded square centered in the 1024 canvas, with room for the system's shadow.
	let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
	let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
	ctx.saveGState()
	platePath.addClip()
	NSColor.black.setFill()
	platePath.fill()
	ctx.restoreGState()

	func screen(_ rect: CGRect, bright: Bool) {
		ctx.saveGState()
		NSColor.white.setFill()
		if bright {
			NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
		} else {
			NSColor.white.setStroke()
			let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 20, yRadius: 20)
			outline.lineWidth = 16
			outline.stroke()
		}
		ctx.restoreGState()
	}
	screen(CGRect(x: 158, y: 372, width: 330, height: 244), bright: true)
	screen(CGRect(x: 536, y: 372, width: 330, height: 244), bright: false)

	// The standard pointer shape, sitting across the gap.
	let tip = CGPoint(x: 462, y: 610)
	let scale: CGFloat = 3.5
	let points: [(CGFloat, CGFloat)] = [(0, 0), (0, -68), (16, -53), (28, -80), (41, -74), (29, -48), (50, -48)]
	let pointer = NSBezierPath()
	for (i, p) in points.enumerated() {
		let at = CGPoint(x: tip.x + p.0 * scale, y: tip.y + p.1 * scale)
		if i == 0 { pointer.move(to: at) } else { pointer.line(to: at) }
	}
	pointer.close()
	pointer.lineJoinStyle = .round
	ctx.saveGState()
	NSColor.black.setStroke()
	pointer.lineWidth = 34
	pointer.stroke()
	ctx.restoreGState()
	NSColor.white.setStroke()
	pointer.lineWidth = 16
	pointer.stroke()
	NSColor.white.setFill()
	pointer.fill()
	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
	try! draw(CGFloat(size)).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
	try! draw(CGFloat(size * 2)).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
