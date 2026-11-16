// swift-tools-version: 6.0
import PackageDescription

// cryo-ci runs GitHub Actions jobs on cryo capsules. It is a client of the bay, like `cryo lease`:
// it uses the cryo package's API types, client and helpers, and talks to the bay over its API.
let core: [Target.Dependency] = [
	.product(name: "CryoAPI", package: "cryo"),
	.product(name: "CryoHTTP", package: "cryo"),
	.product(name: "CryoClient", package: "cryo"),
]

let package = Package(
	name: "cryo-ci",
	platforms: [.macOS("27.0")],
	products: [
		.executable(name: "cryo-ci", targets: ["cryo-ci"])
	],
	dependencies: [
		.package(url: "https://github.com/rizwankce/cryo.git", branch: "main")
	],
	targets: [
		.target(name: "CryoCI", dependencies: core),
		.target(name: "CryoCICLI", dependencies: core + ["CryoCI"]),
		.executableTarget(name: "cryo-ci", dependencies: ["CryoCICLI"]),
		.testTarget(
			name: "CryoCITests",
			dependencies: core + ["CryoCI", "CryoCICLI", .product(name: "FakeBay", package: "cryo")]),
	],
	swiftLanguageModes: [.v6]
)
