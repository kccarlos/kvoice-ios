# App Store metadata (draft)

Character counts were checked with a script. Guideline 2.3.7: no
trademarked or third-party app names in the name, subtitle or keywords.

| Field | Value | Limit |
| --- | --- | --- |
| Name | KVoice Dictation (the current App Store Connect record name; the home screen shows "KVoice") | 16 / 30 |
| Subtitle | Private voice-to-text keyboard | 30 / 30 |
| Keywords | `dictation,voice typing,speech to text,transcribe,keyboard,offline,notes,email,voice memo,AI` | 91 / 100 |
| Primary category | Productivity | |
| Secondary category | Utilities | |
| Support URL | https://github.com/kccarlos/kvoice-ios/blob/main/Docs/Support.md | |
| Privacy Policy URL | https://github.com/kccarlos/kvoice-ios/blob/main/Docs/Privacy.md | |
| Price | Free, no in-app purchases | |

## Promotional text (170 max)

Speak instead of typing. KVoice turns your voice into clean text on your
iPhone, with no account and no servers, and types it into any app from
its keyboard.

## Description

KVoice turns speech into text, then tidies it up the way you want. It runs
on your iPhone by default: no account, no sign-in, no servers, no
analytics.

DICTATE
• Hold the microphone to talk, or tap to start and stop.
• Copy, share or re-run the result with another mode.
• History keeps your dictations on your iPhone, with optional audio.

MODES
• Dictation types exactly what you said.
• Clean up, Message, Email, Notes, Summary and Translate to English
  reformat it with AI.
• Write your own modes with your own instructions and language.

KEYBOARD
• A QWERTY keyboard that types in any app.
• Tap its microphone to dictate: KVoice listens, and the text is typed
  where you left off.

DICTATE FROM ANYWHERE
• Control Center, Lock Screen widgets, the Action Button and Shortcuts.
• A Live Activity shows the recording and lets you stop it.

PRIVATE BY DESIGN
• On-device speech recognition with Apple Speech or downloadable Whisper
  models in 100+ languages.
• On-device formatting with Apple Intelligence on supported iPhones.
• Optional: bring your own API key for a cloud provider. KVoice asks before
  anything is sent, and keys stay in the Keychain.

KVoice is open source.

## Age rating answers

All content questions (violence, sexual content, profanity, horror,
substances, medical, gambling, contests, loot boxes): **None**.

| Question | Answer | Why |
| --- | --- | --- |
| Parental Controls | No | |
| Age Assurance | No | |
| Unrestricted Web Access | No | No web view or browser. |
| User-Generated Content | No | Text stays on the device; nothing is shared with other users. |
| Social Media / Messaging and Chat | No | |
| Advertising | No | |

Expected rating: 4+. The owner confirms in App Store Connect (the
questionnaire changed in 2025; if it asks about AI or chatbot features,
answer that AI only reformats the user's own dictation and has no open
chat).

## App Privacy ("nutrition label")

Answer: **Data Not Collected**. Tracking: **No**.

Rationale, matching the privacy manifests (`NSPrivacyCollectedDataTypes`
empty, `NSPrivacyTracking` false):
- The developer runs no servers and receives no data. No analytics, crash
  reporting or ad SDKs are linked.
- Audio and transcripts go to a cloud provider only when the user chooses
  that provider, enters their own API key and allows it in the consent
  sheet. The request goes directly from the device to the user's own
  account with that provider, which is not the developer's partner.

Owner confirms this judgment. The conservative alternative is to declare
"Audio Data" and "Other User Content" as collected, used for App
Functionality, not linked to identity and not used for tracking.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in the app's Info.plist: KVoice
uses only Apple's HTTPS (URLSession) and the Keychain. App Store Connect
then asks no encryption questions.
