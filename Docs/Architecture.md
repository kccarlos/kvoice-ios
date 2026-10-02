# Architecture

## Targets

| Target | Kind | Links | Role |
| --- | --- | --- | --- |
| `KVoice` | app | `KVoiceKit` | Records, transcribes, formats; all UI; App Intents; answers the keyboard. |
| `KVoiceKeyboard` | keyboard extension | `KVoiceCore` | Picks a mode, hands dictation to the app, types the result. |
| `KVoiceWidgets` | WidgetKit extension | `KVoiceCore` | Control Center control and a home / Lock Screen widget that start a dictation. |
| `KVoiceKitTests` | unit tests | both products | Package tests, run by the `KVoice` scheme. |

`Shared/Intents` (`DictateIntent`, `ModeEntity`) is compiled into the app
and the widget extension; the intent always runs in the app.

## Package `Packages/KVoiceKit`

- `KVoiceCore`: modes and `ModeStore`, `Settings`, `KeychainStore`,
  `AppGroup`, `DictationHandoff`, Darwin notifications. No audio, ML or
  persistence frameworks (a test enforces this): the keyboard extension
  has a tight memory limit.
- `KVoiceKit` (re-exports `KVoiceCore`): `AudioRecorder`, transcription
  engines (Apple Speech, WhisperKit, cloud), AI formatters, `HistoryStore`
  (SwiftData) and `DictationPipeline`. Each vendor SDK is imported by one
  adapter file.

Shared state lives in the App Group: `modes.json`, settings in App Group
defaults, `History.store` and `Recordings/`, and the `Handoff/` mailbox.
API keys are in the Keychain access group
`$(AppIdentifierPrefix)io.github.kccarlos.kvoice.ios.shared`, named by the
`KVoiceKeychainGroup` Info.plist key (`KeychainStore.shared()`; unsigned
builds fall back to the default group).

## Keyboard handoff

iOS keyboards cannot record, so the keyboard asks the app. Files live in
`<App Group>/KVoice/Handoff/`, each write posts a Darwin notification
(`io.github.kccarlos.kvoice.ios.handoff.*`).

1. Keyboard writes `request.json` (`HandoffRequest`: session, mode) with
   `writeRequest`, which also resets `result.json` to `recording`, then
   opens `kvoice://dictate?session=<id>`.
2. The app checks the request (same session, under 120 s old), starts
   recording in that mode, and shows a compact "swipe back" screen.
3. Every pipeline phase is written to `result.json` (`HandoffResult`):
   `recording`, `transcribing`, `formatting`, then `done` with `text`, or
   `failed` with `errorMessage`, or `cancelled`. The keyboard inserts a
   `done` text once and calls `markResultConsumed`.
4. Stop or cancel from the keyboard: write `command.json`
   (`HandoffCommand` `stop` / `cancel` with the session id).
5. Standby: after a keyboard dictation the app keeps the input engine
   running for the "Keep listening for the keyboard" window (default
   5 min) and writes `app-state.json` (`HandoffAppState`,
   `isListeningForCommands`, `expiresAt`). While
   `acceptsCommands()` is true the keyboard can send `start` (with a new
   session id and mode) instead of opening the app. Standby ends on expiry,
   on an audio interruption, or when the setting is off.

iOS keeps an app with the `audio` background mode alive only while audio
I/O runs, and does not let it start recording from the background; standby
therefore keeps the microphone input running (the system microphone
indicator stays on). This must be validated on a device.

`kvoice://dictate` without a session (optionally `?mode=<id>`) starts a
dictation in the app itself; widgets and Control Center use it or
`DictateIntent`.
