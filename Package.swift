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
  ],
  targets: [
    .target(
      name: "PiAIProviderRuntime",
      resources: [.process("Resources")]
    ),
    .executableTarget(
      name: "PiAIAuthProbe",
      dependencies: ["PiAIProviderRuntime"]
    ),
    .testTarget(
      name: "PiAIProviderRuntimeTests",
      dependencies: ["PiAIProviderRuntime"]
    ),
  ]
)
