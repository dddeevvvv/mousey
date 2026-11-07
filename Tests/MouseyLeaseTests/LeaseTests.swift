import XCTest
@testable import MouseyLease

final class LeaseTests: XCTestCase {
	private final class Box: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [Bool] = []
		private var stopped = false
		func add(_ v: Bool) { lock.lock(); values.append(v); lock.unlock() }
		var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
		func stop() { lock.lock(); stopped = true; lock.unlock() }
		var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
	}

	private var path = ""
	private let box = Box()
	private let finished = DispatchSemaphore(value: 0)

	override func setUp() {
		path = "/tmp/mousey-lease-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
	}

	private func start(allowedUID: uid_t = getuid()) {
		let server = LeaseServer(path: path, allowedUID: allowedUID, tickMillis: 10, apply: box.add)!
		let (box, finished) = (box, finished)
		Thread.detachNewThread {
			server.run { box.isStopped }
			finished.signal()
		}
		wait { box.all == [false] }
	}

	private func wait(_ what: String = "condition", _ condition: () -> Bool) {
		let end = Date().addingTimeInterval(3)
		while !condition(), Date() < end { usleep(2000) }
		XCTAssertTrue(condition(), what)
	}

	private func stopServer() {
		box.stop()
		XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
	}

	func testHeldExactlyWhileAConnectionIsOpen() {
		start()
		let first = Lease.connect(path: path)!
		wait("first lease turns it off") { box.all.last == true }
		let second = Lease.connect(path: path)!
		close(first)
		usleep(50_000)
		XCTAssertEqual(box.all.last, true, "the second lease still holds it")
		close(second)
		wait("the last lease ending turns it back on") { box.all.last == false }
		stopServer()
	}

	func testAHeldLeaseIsReappliedSoTheSystemCannotUndoIt() {
		start()
		let fd = Lease.connect(path: path)!
		wait("applied on every tick") { box.all.filter { $0 }.count >= 3 }
		close(fd)
		stopServer()
	}

	func testAnotherUserGetsNoLease() {
		start(allowedUID: getuid() &+ 1)
		let fd = Lease.connect(path: path)
		if let fd {
			wait("the connection is closed on them") { !Lease.isOpen(fd) }
			close(fd)
		}
		XCTAssertFalse(box.all.contains(true))
		stopServer()
	}

	func testAClientThatSendsDataLosesItsLease() {
		start()
		let fd = Lease.connect(path: path)!
		wait { box.all.last == true }
		let junk = [UInt8](repeating: 0x41, count: 4096)
		_ = send(fd, junk, junk.count, 0)
		wait("the flood cannot keep the lease or spin the loop") { box.all.last == false }
		close(fd)
		stopServer()
	}

	func testTheSocketIsPrivateFromTheStart() {
		start()
		var info = stat()
		XCTAssertEqual(stat(path, &info), 0)
		XCTAssertEqual(info.st_mode & 0o777, 0o600)
		XCTAssertEqual(info.st_uid, getuid())
		stopServer()
		XCTAssertFalse(FileManager.default.fileExists(atPath: path), "gone once the server stops")
	}

	func testStoppingWhileHeldTurnsItBackOn() {
		start()
		let fd = Lease.connect(path: path)!
		wait { box.all.last == true }
		stopServer()
		XCTAssertEqual(box.all.last, false)
		XCTAssertFalse(Lease.isOpen(fd), "the holder can see that its lease ended")
		close(fd)
	}

	func testStoppingRemovesItsOwnSocket() {
		start()
		XCTAssertTrue(FileManager.default.fileExists(atPath: path))
		stopServer()
		XCTAssertFalse(FileManager.default.fileExists(atPath: path))
	}

	func testStoppingLeavesANewerHelpersSocketAlone() {
		start()
		unlink(path)
		XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
		stopServer()
		XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the path belongs to the newer helper now")
		unlink(path)
	}

	func testCopyingTheHelperLeavesItsSourcesPermissionsBehind() throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let source = folder.appendingPathComponent("source").path
		let destination = folder.appendingPathComponent("destination").path
		let bytes = Data((0..<4096).map { UInt8($0 % 251) })
		try bytes.write(to: URL(fileURLWithPath: source))
		let chmod = Process()
		chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
		chmod.arguments = ["+a", "user:\(NSUserName()) allow write", source]
		try chmod.run()
		chmod.waitUntilExit()
		XCTAssertEqual(setxattr(source, "com.example.planted", "x", 1, 0, 0), 0)
		func hasACL(_ path: String) -> Bool {
			guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return false }
			acl_free(UnsafeMutableRawPointer(acl))
			return true
		}
		XCTAssertTrue(hasACL(source), "the source must really have an ACL, or this test proves nothing")
		XCTAssertTrue(Lease.copyContents(from: source, to: destination))
		XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), bytes)
		XCTAssertFalse(hasACL(destination))
		XCTAssertEqual(getxattr(destination, "com.example.planted", nil, 0, 0, 0), -1)
	}

	func testNoHelperMeansNoLease() {
		XCTAssertNil(Lease.connect(path: path))
	}

	func testAPathTooLongForASocketIsRefused() {
		let long = "/tmp/" + String(repeating: "x", count: 200)
		XCTAssertNil(Lease.connect(path: long))
		XCTAssertNil(LeaseServer(path: long, allowedUID: getuid(), apply: { _ in }))
	}
}
