import Foundation

/// One line per lifecycle change, in `~/Library/Logs/Mousey/app.log`. Never input: no key codes and no event bytes.
enum Log {
	private static let queue = DispatchQueue(label: "mousey-log")
	private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mousey/app.log")
	private static let maxBytes = 1_000_000

	static func write(_ line: String) {
		let entry = Data("\(Date()) \(line)\n".utf8)
		queue.async {
			try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes { try? FileManager.default.removeItem(at: url) }
			guard let handle = try? FileHandle(forWritingTo: url) else {
				try? entry.write(to: url)
				return
			}
			handle.seekToEndOfFile()
			handle.write(entry)
			handle.closeFile()
		}
	}
}
