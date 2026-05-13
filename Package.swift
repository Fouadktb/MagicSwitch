// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "MagicSwitch",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "MagicSwitchCore", targets: ["MagicSwitchCore"]),
    .executable(name: "MagicSwitch", targets: ["MagicSwitchApp"]),
  ],
  targets: [
    .target(name: "MagicSwitchCore"),
    .executableTarget(
      name: "MagicSwitchApp",
      dependencies: ["MagicSwitchCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("IOBluetooth"),
        .linkedFramework("Network"),
      ]
    ),
  ]
)
