// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KVoiceKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KVoiceKit", targets: ["KVoiceKit"])
    ],
    targets: [
        .target(name: "KVoiceKit"),
        .testTarget(name: "KVoiceKitTests", dependencies: ["KVoiceKit"])
    ]
)
