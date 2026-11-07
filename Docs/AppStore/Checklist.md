# App Store readiness checklist

Checked against the App Review Guidelines (developer.apple.com/app-store/review/guidelines,
read November 2026) and Apple's privacy manifest and screenshot docs.
Status: **done**, **owner** (needs the owner, usually in App Store
Connect) or **risk** (a known review risk with our rationale).

## Guidelines

| Item | Status | Evidence |
| --- | --- | --- |
| 2.1(a) Complete, no placeholders, demo account if login | done | No login. On-device default works without keys (see Reviewer path). |
| 2.3.1(a) Review notes describe features specifically | done | `ReviewNotes.md`. Owner pastes it into App Review Information. |
| 2.3.7 Name ≤ 30, no trademarks in metadata | done | `Metadata.md` (16 / 30, subtitle 30 / 30, keywords 91 / 100; no provider names in keywords). |
| 2.5.1 Public APIs only | risk | The keyboard opens its containing app by walking the responder chain to `UIApplication` and calling `openURL:` (`Keyboard/Sources/AppURLOpener.swift`). There is no public "open containing app" API for keyboards. Rationale is in the review notes. If rejected, the fallback is a "Open KVoice" instruction instead of opening it. |
| 2.5.4 Background services only for their purpose | risk | `UIBackgroundModes: audio` is used only to record a dictation the user started, and for the keyboard standby (microphone kept ready up to 5 min by default, Off available, Live Activity and mic indicator shown). Explained in the review notes; the mic prompt now mentions standby. |
| 2.5.16 Extensions related to the app | done | Keyboard dictates, widgets/controls start dictation, Live Activity shows it. |
| 4.4.1 Keyboard: typed input, next-keyboard key, works without Full Access or network | done | QWERTY keys, globe key (`handleInputModeList(from:with:)`), typing without Full Access (`KeyboardModel.hasFullAccess` gates only dictation and haptics). Tour shots 50-56. |
| 4.4.1 Keyboard: collects activity only for the keyboard | done | The keyboard logs nothing and sends nothing; Full Access is used for the App Group handoff only. |
| 4.4.1 Keyboard: must not launch other apps besides Settings | risk | The microphone key opens KVoice itself (its containing app, user tap only), because keyboards cannot record audio. Explained in the review notes. |
| 5.1.1(i) Privacy policy linked in ASC and in the app | done / owner | `Docs/Privacy.md`, linked in Settings › About. Owner enters the URL in App Store Connect; the GitHub URL works only after this branch is merged to `main`. |
| 5.1.1(i) Policy explains retention, deletion, consent withdrawal | done | Privacy.md "What stays on your iPhone" and "Your choices". |
| 5.1.1(ii) Consent and an easy way to withdraw it | done | Consent sheet per cloud provider; Settings › Privacy › Stop Sending to *provider*. Purpose strings for microphone and speech recognition are accurate. |
| 5.1.1(v) No login for non-account features | done | No accounts at all. |
| 5.1.2(i) Explicit permission before sharing with third-party AI | done | `CloudConsentSheet` before first use; `DictationPipeline` refuses a cloud engine or formatter without consent, so background runs (keyboard, Action Button, Transcribe Audio, re-run) fail with "Nothing was sent to …" (`CloudConsentTests`). Formatting without consent keeps the transcript. |
| 5.1.2(i) No tracking / ATT | done | No tracking, no ATT prompt needed. |

## Build and privacy

| Item | Status | Evidence |
| --- | --- | --- |
| Privacy manifests | done | `App/Resources`, `Keyboard/Sources`, `Widgets/Sources` `PrivacyInfo.xcprivacy`; one per built bundle, `plutil -lint` OK. UserDefaults `1C8F.1` (App Group) and `CA92.1` in all three; file timestamps `C617.1` in the app (`HistoryStore` recording clean-up, WhisperKit downloader `attributesOfItem`). No boot-time, disk-space or active-keyboard APIs found by grep. |
| KVoiceKit package manifest | done | Not added: KVoiceKit is first-party code linked statically into the targets, whose manifests declare its API use. A package resource would add a bundle to the memory-limited keyboard. WhisperKit (argmax-oss-swift 1.1.0) ships no manifest; the app's manifest covers its use. |
| App Privacy label | owner | Proposed "Data Not Collected" with rationale in `Metadata.md`; owner confirms. |
| Export compliance | done | `ITSAppUsesNonExemptEncryption = false` (only Apple HTTPS and Keychain). |
| iPhone only | done | `TARGETED_DEVICE_FAMILY = 1` for every target (verified with `-showBuildSettings`); iPad orientations removed. No version has been released (App Store Connect: iOS 1.0 Prepare for Submission), so dropping iPad is allowed. |
| Third-party licenses | done | Settings › About › Third-Party Licenses shows `ThirdPartyLicenses.txt`: WhisperKit / argmax-oss-swift (MIT) and its swift-transformers portions (Apache-2.0). swift-argument-parser is only used by Argmax's CLI target and does not ship. |
| Debug-only UI compiled out of Release | done | `#if DEBUG` covers demo data, keyboard preview, Diagnostics start strategy and the Action Button state tester; their long strings are absent from the Release binary (`strings`). The `-kvoiceTab` / `-kvoiceScreen` / `-kvoiceOpenURL` launch arguments stay in Release; users cannot pass launch arguments, so this is harmless. |
| Release build | done | `xcodebuild -configuration Release` for the simulator succeeds. |

## Reviewer path without API keys

| Item | Status | Evidence |
| --- | --- | --- |
| Fresh install dictates with Apple Speech | done (code and tests) | `Settings()` defaults to Apple Speech and Apple Intelligence; AI modes fall back to Dictation when Apple Intelligence is unavailable (`AIReadinessTests`). Not run on a freshly erased device. |
| Keyboard types without Full Access | done | Tour shot `55-keyboard-noFullAccess`; `KeyboardExtensionUITests` types with the real keyboard on a device. |

## For the owner in App Store Connect

1. Merge to `main` so the Privacy and Support URLs resolve, then enter
   them (App Information › Privacy Policy URL; version › Support URL).
2. Paste `ReviewNotes.md` into App Review Information › Notes; no demo
   account; sign-in not required.
3. Fill name, subtitle, promotional text, description, keywords and
   categories from `Metadata.md`.
4. Answer the age rating questionnaire (`Metadata.md`, expected 4+).
5. App Privacy: confirm "Data Not Collected" (or the conservative
   alternative in `Metadata.md`).
6. Upload screenshots per `Screenshots.md` (at least the 6.3-inch medium
   Dynamic Island set; 6.9-inch recommended).
7. Upload a new build from this branch (the existing builds 6-8 still
   declare iPad support).
8. Content rights: KVoice shows no third-party content. Pricing: free.
