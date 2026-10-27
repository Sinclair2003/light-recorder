// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SimpleRecorder", targets: ["RecorderApp"]),
        .executable(name: "RecorderSelfTest", targets: ["RecorderSelfTest"])
    ],
    targets: [
        .target(name: "RecorderCore"),
        .executableTarget(name: "RecorderApp", dependencies: ["RecorderCore"]),
        .executableTarget(name: "RecorderSelfTest", dependencies: ["RecorderCore"], path: "Tests/RecorderCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
