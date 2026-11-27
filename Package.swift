// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "CodexUsageMenuBar",
  platforms: [.macOS(.v15)],
  products: [
    .executable(
      name: "CodexUsageMenuBar",
      targets: ["CodexUsageMenuBar"]
    )
  ],
  targets: [
    .executableTarget(
      name: "CodexUsageMenuBar",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "CodexUsageMenuBarTests",
      dependencies: ["CodexUsageMenuBar"]
    ),
  ]
)
