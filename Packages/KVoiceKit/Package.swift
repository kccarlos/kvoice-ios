// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KVoiceKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KVoiceKit", targets: ["KVoiceKit"])
    ],
    dependencies: [
        // On-device Whisper. The exact pin is deliberate: the short-clip
        // padding and silence gate are tuned against this release.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .target(
            name: "KVoiceKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .testTarget(name: "KVoiceKitTests", dependencies: ["KVoiceKit"])
    ],
    swiftLanguageModes: [.v6]
)
