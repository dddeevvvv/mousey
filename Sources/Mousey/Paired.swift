import Foundation
import MouseyCore
import Security

/// The app's saved choices, in the `io.github.imsumitkumar.mousey` defaults domain. The link key is in the Keychain, never here.
enum Settings {
	static let edges: [String: Edge] = ["left": .left, "right": .right, "top": .top, "bottom": .bottom]
	static let edgeNames: [Edge: String] = [.left: "left", .right: "right", .top: "top", .bottom: "bottom"]
	private static let defaults = UserDefaults.standard

	/// This Mac's identity in pairing and discovery. Made once.
	static var localID: String {
		if let id = defaults.string(forKey: "localID") { return id }
		let id = UUID().uuidString
		defaults.set(id, forKey: "localID")
		return id
	}
	static var role: Role? {
		get { defaults.string(forKey: "role").flatMap(Role.init(rawValue:)) }
		set { defaults.set(newValue?.rawValue, forKey: "role") }
	}
	static var peerID: String? {
		get { defaults.string(forKey: "peerID") }
		set { defaults.set(newValue, forKey: "peerID") }
	}
	static var peerName: String? {
		get { defaults.string(forKey: "peerName") }
		set { defaults.set(newValue, forKey: "peerName") }
	}
	/// Only for networks where discovery cannot work.
	static var address: String? {
		get { defaults.string(forKey: "address") }
		set { defaults.set(newValue, forKey: "address") }
	}
	static var edge: Edge {
		get { defaults.string(forKey: "edge").flatMap { edges[$0] } ?? .left }
		set { defaults.set(edgeNames[newValue], forKey: "edge") }
	}
	/// Off until the person turns it on, on each Mac.
	static var clipboardSharing: Bool {
		get { defaults.bool(forKey: "clipboardSharing") }
		set { defaults.set(newValue, forKey: "clipboardSharing") }
	}
	/// macOS's own dialog has appeared once. It adds the app to the Accessibility list, and it does not appear a second time.
	static var askedForAccessibility: Bool {
		get { defaults.bool(forKey: "askedForAccessibility") }
		set { defaults.set(newValue, forKey: "askedForAccessibility") }
	}
	static var onboardingStep: String? {
		get { defaults.string(forKey: "onboardingStep") }
		set { defaults.set(newValue, forKey: "onboardingStep") }
	}
	private static let updateChecksStartOn = true
	static var updates: UpdateState {
		get {
			UpdateState(enabled: defaults.object(forKey: "checkForUpdates") as? Bool ?? updateChecksStartOn, lastCheck: defaults.object(forKey: "lastUpdateCheck") as? Date, latestTag: defaults.string(forKey: "latestRelease"))
		}
		set {
			defaults.set(newValue.enabled, forKey: "checkForUpdates")
			defaults.set(newValue.lastCheck, forKey: "lastUpdateCheck")
			defaults.set(newValue.latestTag, forKey: "latestRelease")
		}
	}
}

enum Role: String { case controller, target }

/// SwiftUI has its own `Edge`. This app means the screen edge the pointer crosses.
typealias Edge = MouseyCore.Edge

/// The link key. Reading it back after a rebuild asks nothing, because the signature's identity stays the same.
struct KeyStore {
	var service = "io.github.imsumitkumar.mousey.link"
	private let account = "paired-mac"

	private var query: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
	}

	func load() -> Data? {
		var result: CFTypeRef?
		var q = query
		q[kSecReturnData as String] = true
		guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
		return result as? Data
	}

	@discardableResult
	func save(_ key: Data) -> Bool {
		SecItemDelete(query as CFDictionary)
		var q = query
		q[kSecValueData as String] = key
		return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
	}

	func delete() { SecItemDelete(query as CFDictionary) }
}

func localAddresses() -> [String] {
	var list: UnsafeMutablePointer<ifaddrs>?
	guard getifaddrs(&list) == 0, let first = list else { return [] }
	defer { freeifaddrs(list) }
	var out: [String] = []
	for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
		let a = p.pointee
		guard a.ifa_flags & UInt32(IFF_UP) != 0, a.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let addr = a.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
		var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
		if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { out.append(String(cString: host)) }
	}
	return out
}

/// Installs and removes the AWDL helper behind the system's own password prompt.
enum HelperInstaller {
	static let installedPath = "/Library/PrivilegedHelperTools/io.github.imsumitkumar.mousey.awdl-helper"

	static func install(completion: @escaping (String?) -> Void) {
		let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MouseyHelper").path
		run("\(quoted(helper)) --install --uid \(getuid())", completion: completion)
	}

	static func remove(completion: @escaping (String?) -> Void) {
		run("\(quoted(installedPath)) --uninstall", completion: completion)
	}

	private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

	/// Reports nil on success, or a sentence to show.
	private static func run(_ command: String, completion: @escaping (String?) -> Void) {
		DispatchQueue.global().async {
			let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
			var error: NSDictionary?
			NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
			let code = error?[NSAppleScript.errorNumber] as? Int
			let message = code == -128 ? "Cancelled." : (error?[NSAppleScript.errorMessage] as? String)
			DispatchQueue.main.async { completion(message) }
		}
	}
}
