// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "Mousey",
	platforms: [.macOS(.v12)],
	targets: [
		.target(name: "MouseyCore"),
		.target(name: "MouseyLease"),
		.target(name: "MouseyPair"),
		.target(name: "MouseyClip"),
		.executableTarget(name: "Mousey", dependencies: ["MouseyCore", "MouseyLease", "MouseyPair", "MouseyClip"]),
		.executableTarget(name: "MouseyHelper", dependencies: ["MouseyLease"]),
		.testTarget(name: "MouseyCoreTests", dependencies: ["MouseyCore"]),
		.testTarget(name: "MouseyLeaseTests", dependencies: ["MouseyLease"]),
		.testTarget(name: "MouseyPairTests", dependencies: ["MouseyPair"]),
		.testTarget(name: "MouseyClipTests", dependencies: ["MouseyClip"]),
	]
)
