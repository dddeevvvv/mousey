import Foundation

let args = Array(CommandLine.arguments.dropFirst())

// The test modes post events with this app's Accessibility permission, so in a release build any program could borrow it.
#if DEBUG
let recording = args.count > 1 ? args[1] : "Tests/Fixtures/trackpad-recording.json"
switch args.first {
case "--selftest":
	exit(runSelfTest(recording: recording))
case "--selftest-inject":
	runSelfTestInject(recording: recording)
case "--selftest-dock":
	runSelfTestDock(recording: recording)
case "--selftest-loop":
	runSelfTestLoop(recording: recording)
case "--render-screens":
	renderScreens(to: args.count > 1 ? args[1] : "screens")
case "--selftest-live":
	exit(runSelfTestLive())
default:
	break
}
#endif

guard args.isEmpty else {
	fputs("unknown argument\n", stderr)
	exit(64)
}
runApp()
