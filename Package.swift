// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "pi-ai-swift",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "PiAIProviderRuntime",
      targets: ["PiAIProviderRuntime"]
    ),
    .executable(
      name: "pi-ai-auth-probe",
      targets: ["PiAIAuthProbe"]
    ),
    .executable(
      name: "pi-ai-live-probe",
      targets: ["PiAILiveProbe"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7")
  ],
  targets: [
    .target(
      name: "PiAIProviderRuntime",
      dependencies: [.product(name: "libzstd", package: "zstd")],
      resources: [.process("Resources")]
    ),
    .executableTarget(
      name: "PiAIAuthProbe",
      dependencies: ["PiAIProviderRuntime"]
    ),
    .executableTarget(
      name: "PiAILiveProbe",
      dependencies: ["PiAIProviderRuntime"]
    ),
    .testTarget(
      name: "PiAIProviderRuntimeTests",
      dependencies: ["PiAIProviderRuntime"]
    ),
  ]
)
