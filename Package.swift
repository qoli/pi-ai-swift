// swift-tools-version: 6.1

import PackageDescription

#if os(Linux)
  let platformDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")
  ]
  let platformProducts: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
  let platformDependencies: [Package.Dependency] = []
  let platformProducts: [Target.Dependency] = []
#endif

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
  ] + platformDependencies,
  targets: [
    .target(
      name: "PiAIProviderRuntime",
      dependencies: [.product(name: "libzstd", package: "zstd")] + platformProducts,
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
      dependencies: [.target(name: "PiAIProviderRuntime")] + platformProducts
    ),
  ]
)
