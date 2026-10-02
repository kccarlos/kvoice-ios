// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KVoiceKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // Domain, settings, Keychain and keyboard handoff. No vendor SDKs, no
        // audio or ML frameworks: safe for the memory-limited keyboard.
        .library(name: "KVoiceCore", targets: ["KVoiceCore"]),
        // Recording, transcription engines, AI formatters, history and the
        // dictation pipeline (re-exports KVoiceCore). App only.
        .library(name: "KVoiceKit", targets: ["KVoiceKit"])
    ],
    dependencies: [
        // On-device Whisper. The exact pin is deliberate: the short-clip
        // padding and silence gate are tuned against this release.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "KVoiceCore"),
        .target(
            name: "KVoiceKit",
            dependencies: [
                "KVoiceCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .testTarget(name: "KVoiceKitTests", dependencies: ["KVoiceKit", "KVoiceCore"])
    ],
    swiftLanguageModes: [.v6]
)
