import Foundation
import MouseyLease

/// Keeps AWDL off while input crosses between the Macs. Runs on its own queue, so the input threads never wait on it.
/// With no helper installed, nothing changes except one log line.
final class AwdlLease {
	static let shared = AwdlLease()
	/// Going back and forth should not switch the radio each time, so the lease outlives a return by this long.
	private static let lingerSeconds = 30.0

	private let queue = DispatchQueue(label: "mousey-awdl-lease")
	private var fd: Int32?
	private var pendingRelease: DispatchWorkItem?
	private var loggedMissing = false

	func hold() {
		queue.async { [self] in
			pendingRelease?.cancel()
			pendingRelease = nil
			if let fd, Lease.isOpen(fd) { return }
			if let fd { close(fd) }
			fd = Lease.connect()
			if fd != nil {
				loggedMissing = false
				Log.write("holding the AWDL lease")
			} else if !loggedMissing {
				loggedMissing = true
				Log.write("no AWDL helper answered, Wi-Fi may stall")
			}
		}
	}

	func letGo() {
		queue.async { [self] in
			pendingRelease?.cancel()
			let release = DispatchWorkItem { [self] in
				guard let fd else { return }
				close(fd)
				self.fd = nil
				Log.write("released the AWDL lease")
			}
			pendingRelease = release
			queue.asyncAfter(deadline: .now() + Self.lingerSeconds, execute: release)
		}
	}
}
