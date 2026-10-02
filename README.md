# KVoice for iOS

Speak once, get finished text in any app on iPhone and iPad. Dictation with
optional AI formatting, on-device speech recognition, and your choice of AI
provider: Apple Intelligence on device, or your own API key.

Status: early development. Builds go to TestFlight on every push to `main`.

## Functional requirements

### Capture
- FR-1 Record with a hold-to-talk or tap-to-toggle control; stop inserts the result.
- FR-2 Start dictation from anywhere: a custom keyboard, an App Shortcut /
  Siri phrase, the Action Button, and a Control Center control.
- FR-3 The custom keyboard switches to the app to record (iOS keyboards
  cannot use the microphone), then returns and types the result into the
  text field that was active.
- FR-4 Recording keeps running briefly in the background so the keyboard
  can start the next dictation without opening the app again.

### Transcription
- FR-10 On-device transcription with Apple's speech framework (no download).
- FR-11 On-device Whisper models (downloadable), 100+ languages, with
  optional translation to English.
- FR-12 Cloud transcription with the user's own key: any OpenAI-compatible
  transcription endpoint (OpenAI, Groq, custom URL), Google AI Studio
  (Gemini API) or Google Vertex AI (express-mode key or a project and
  location endpoint).
- FR-13 Language: automatic detection or a fixed language per mode.

### AI formatting (modes)
- FR-20 Modes turn a transcript into a finished format: plain dictation
  (no AI), clean-up, message, email, notes, summary, translate.
- FR-21 Custom modes: name, prompt/instructions, language, AI provider and
  model, and transcription engine, saved and reused.
- FR-22 Switch the active mode from the keyboard and from the app.
- FR-23 AI providers: Apple Intelligence (on-device Foundation Models), or
  bring your own key for OpenAI, Anthropic, Google AI Studio (Gemini API),
  Google Vertex AI, Groq, OpenRouter, or any OpenAI-compatible endpoint.
- FR-24 Plain dictation works with no AI and no network.

### History
- FR-30 Every recording keeps its audio, raw transcript, and formatted
  result on the device.
- FR-31 Full-text search across the history; copy, share, re-run with a
  different mode, delete.
- FR-32 Retention setting (keep forever, 30 days, 7 days, never keep audio).

### Privacy and security
- FR-40 Recordings and transcripts stay on the device. Nothing is sent
  anywhere unless the user picks a cloud provider.
- FR-41 API keys are stored in the Keychain, shared with the keyboard only
  through the app's Keychain access group.
- FR-42 No analytics, no accounts.

## Building

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM
Scripts/generate.sh
open KVoice.xcodeproj
```

CI and TestFlight: [Docs/CI.md](Docs/CI.md).

## License

MIT
