import Foundation
import MouseyLease

// Runs as root once installed. It can do one thing: switch AWDL, the radio mode whose channel hops stall Wi-Fi for
// about 90 ms every 524 ms (measured). It lives in a root-owned folder because the app in /Applications can be changed
// without an admin password, and root must never run a file like that.
let label = "io.github.imsumitkumar.mousey.awdl-helper"
let installedPath = "/Library/PrivilegedHelperTools/\(label)"
let plistPath = "/Library/LaunchDaemons/\(label).plist"

func awdlIsUp() -> Bool? {
	var list: UnsafeMutablePointer<ifaddrs>?
	guard getifaddrs(&list) == 0, let first = list else { return nil }
	defer { freeifaddrs(list) }
	for p in sequence(first: first, next: { $0.pointee.ifa_next }) where String(cString: p.pointee.ifa_name) == "awdl0" {
		return p.pointee.ifa_flags & UInt32(IFF_UP) != 0
	}
	return nil
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Int32 {
	autoreleasepool {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: tool)
	process.arguments = arguments
	process.standardOutput = FileHandle.nullDevice
	guard (try? process.run()) != nil else { return -1 }
	process.waitUntilExit()
	return process.terminationStatus
	}
}

func applyLease(held: Bool) {
	guard let up = awdlIsUp(), up == held else { return }
	let status = run("/sbin/ifconfig", ["awdl0", held ? "down" : "up"])
	NSLog("AWDL \(held ? "off" : "on"), ifconfig status \(status)")
}

func fail(_ message: String) -> Never {
	fputs("\(message)\n", stderr)
	exit(1)
}

/// Not `Bundle.main`, which inside the app resolves to the app's own executable.
func ownPath() -> String? {
	var size: UInt32 = 4096
	var buffer = [CChar](repeating: 0, count: Int(size))
	guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return nil }
	defer { free(real) }
	return String(cString: real)
}

func remove() {
	if FileManager.default.fileExists(atPath: plistPath) {
		let status = run("/bin/launchctl", ["bootout", "system/\(label)"])
		if status != 0 { print("launchctl bootout returned \(status). A restart finishes the removal.") }
	}
	unlink(Lease.socketPath)
	try? FileManager.default.removeItem(atPath: plistPath)
	try? FileManager.default.removeItem(atPath: installedPath)
}

func install() -> Never {
	// `--uid` comes from the app's password prompt, which has no SUDO_UID. Being root already is what makes either one safe to trust.
	let given = arguments.count == 3 && arguments[1] == "--uid" ? arguments[2] : ProcessInfo.processInfo.environment["SUDO_UID"]
	guard geteuid() == 0, let given, let uid = uid_t(given), uid != 0 else {
		fail("Run this with sudo from your own account.")
	}
	guard let source = ownPath() else { fail("Cannot find this program's own path.") }
	remove()
	let files = FileManager.default
	do {
		try files.createDirectory(atPath: (installedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
			attributes: [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755])
		guard Lease.copyContents(from: source, to: installedPath) else { throw CocoaError(.fileWriteUnknown) }
		try files.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755], ofItemAtPath: installedPath)
		let plist: [String: Any] = ["Label": label, "ProgramArguments": [installedPath, "--serve", String(uid)], "RunAtLoad": true, "KeepAlive": true]
		try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: plistPath))
		try files.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644], ofItemAtPath: plistPath)
	} catch {
		remove()
		fail("Install failed: \(error)")
	}
	let status = run("/bin/launchctl", ["bootstrap", "system", plistPath])
	for _ in 0..<30 where !files.fileExists(atPath: Lease.socketPath) { usleep(100_000) }
	guard status == 0, files.fileExists(atPath: Lease.socketPath) else {
		remove()
		fail("The helper did not start (launchctl status \(status)). Nothing is left installed.")
	}
	print("Installed. AWDL now turns off only while you use Mousey across Macs.")
	print("To remove it: sudo \(installedPath) --uninstall")
	exit(0)
}

func uninstall() -> Never {
	guard geteuid() == 0 else { fail("Run this with sudo.") }
	remove()
	applyLease(held: false)
	print("Removed, and AWDL is on.")
	exit(0)
}

func serve(allowedUID: uid_t) -> Never {
	guard let server = LeaseServer(allowedUID: allowedUID, apply: applyLease) else { fail("Cannot open \(Lease.socketPath)") }
	signal(SIGTERM, SIG_IGN)
	// The loop alone switches AWDL, so a signal cannot race it and leave AWDL off with no daemon running.
	let stopping = DispatchSemaphore(value: 0)
	let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
	terminate.setEventHandler { stopping.signal() }
	terminate.resume()
	server.run { stopping.wait(timeout: .now()) == .success }
	exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--install": install()
case "--uninstall": uninstall()
case "--self-path": print(ownPath() ?? "unknown")
case "--serve":
	guard arguments.count == 2, let uid = uid_t(arguments[1]) else { fail("usage: --serve <uid>") }
	serve(allowedUID: uid)
default:
	fail("usage: sudo \(CommandLine.arguments[0]) --install")
}
