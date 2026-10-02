# KVoice for iOS: agent notes

`CLAUDE.md` is a symlink to this file.

- iOS 26+, Swift 6 strict concurrency, SwiftUI. Targets: `KVoice` app,
  `KVoiceKeyboard` extension, `KVoiceWidgets` extension, local package
  `Packages/KVoiceKit` (all logic and tests live there; the targets stay
  thin). See `Docs/Architecture.md`.
- Extensions link only the `KVoiceCore` product (no WhisperKit, Speech,
  FoundationModels, AVFoundation or SwiftData); the app links `KVoiceKit`.
- The Xcode project is generated: edit `project.yml`, run `Scripts/generate.sh`.
  Never commit `KVoice.xcodeproj`.
- Test: `xcodebuild test -project KVoice.xcodeproj -scheme KVoice -destination "$(Scripts/ci/pick-simulator.sh)" CODE_SIGNING_ALLOWED=NO`.
- Public repo: no personal data, team IDs, keys, or local paths in tracked
  files. Machine-specific settings go in `Config/Local.xcconfig` (untracked).
- Vendor SDKs (WhisperKit, FoundationModels, Speech) stay behind protocols in
  KVoiceKit; one file per adapter imports the vendor module.
- API keys live in the Keychain only, never in UserDefaults or files.
- Conventional Commits.
