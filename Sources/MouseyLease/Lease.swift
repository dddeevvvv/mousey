import Darwin

/// A lease is an open connection to the helper, and AWDL stays off exactly while one exists. The helper reads no
/// commands, so it has nothing to parse, and a client that crashes or quits ends its lease by the same path as one that
/// lets go.
public enum Lease {
	public static let socketPath = "/var/run/io.github.imsumitkumar.mousey.awdl.sock"

	/// An open descriptor that holds the lease until closed, or nil when no helper answers.
	public static func connect(path: String = socketPath) -> Int32? {
		guard var address = unixAddress(path) else { return nil }
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return nil }
		let result = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
		guard result == 0 else {
			close(fd)
			return nil
		}
		return fd
	}

	/// False once the helper has gone away, which ends the lease without telling the holder.
	public static func isOpen(_ fd: Int32) -> Bool {
		var byte: UInt8 = 0
		return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) != 0
	}

	/// Bytes only. A full copy would keep the source's ACL, and whoever that names could rewrite a file root runs.
	public static func copyContents(from source: String, to destination: String) -> Bool {
		copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
	}
}

func unixAddress(_ path: String) -> sockaddr_un? {
	var address = sockaddr_un()
	address.sun_family = sa_family_t(AF_UNIX)
	address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
	let bytes = Array(path.utf8CString)
	guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
	withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
	return address
}

/// Tells `apply` whether a lease is held: once on start with false, on every change, and once per tick while held, so
/// the system turning the radio mode back on is undone. `apply` must be idempotent.
public final class LeaseServer {
	private static let maxClients = 16
	private let path: String
	private let listener: Int32
	private let allowedUID: uid_t
	private let tickMillis: Int32
	private let apply: (Bool) -> Void
	private var socketFile: (inode: UInt64, device: Int32)?

	public init?(path: String = Lease.socketPath, allowedUID: uid_t, tickMillis: Int32 = 1000, apply: @escaping (Bool) -> Void) {
		guard var address = unixAddress(path) else { return nil }
		self.path = path
		self.allowedUID = allowedUID
		self.tickMillis = tickMillis
		self.apply = apply
		listener = socket(AF_UNIX, SOCK_STREAM, 0)
		guard listener >= 0 else { return nil }
		unlink(path)
		// Private from the moment it exists, then handed to the one user allowed to connect.
		let previous = umask(0o177)
		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
		umask(previous)
		guard bound == 0, geteuid() != 0 || chown(path, allowedUID, 0) == 0, listen(listener, 8) == 0 else {
			close(listener)
			return nil
		}
		var made = Darwin.stat()
		if lstat(path, &made) == 0 { socketFile = (made.st_ino, made.st_dev) }
	}

	public func run(until stop: () -> Bool = { false }) {
		var clients: [Int32] = []
		var held = false
		apply(false)
		while !stop() {
			var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)] + clients.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
			_ = poll(&fds, nfds_t(fds.count), tickMillis)
			if fds[0].revents != 0 {
				let client = accept(listener, nil, nil)
				if client >= 0 {
					var uid: uid_t = 0, gid: gid_t = 0
					if clients.count < Self.maxClients, getpeereid(client, &uid, &gid) == 0, uid == allowedUID {
						clients.append(client)
					} else {
						close(client)
					}
				}
			}
			for entry in fds.dropFirst() where entry.revents != 0 {
				// An honest client sends nothing, so any data ends the lease. Reading and carrying on would let a flood spin this loop as root.
				var byte: UInt8 = 0
				let n = recv(entry.fd, &byte, 1, MSG_DONTWAIT)
				if n >= 0 || (errno != EAGAIN && errno != EINTR) {
					close(entry.fd)
					clients.removeAll { $0 == entry.fd }
				}
			}
			let now = !clients.isEmpty
			if now || now != held { apply(now) }
			held = now
		}
		clients.forEach { close($0) }
		close(listener)
		// A newer helper may already hold this path, and its socket is not ours to remove.
		var now = Darwin.stat()
		if lstat(path, &now) == 0, let socketFile, now.st_ino == socketFile.inode, now.st_dev == socketFile.device { unlink(path) }
		if held { apply(false) }
	}
}
