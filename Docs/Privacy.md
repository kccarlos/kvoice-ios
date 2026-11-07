# KVoice privacy policy

Last updated: November 2026

KVoice turns your voice into text on your iPhone. This policy covers the
KVoice app, the KVoice keyboard and the KVoice widgets.

## The short version

- KVoice has no servers, no accounts, no analytics, no advertising and no
  tracking. The developer receives none of your data.
- By default everything runs on your iPhone: Apple Speech or Whisper turn
  speech into text, and Apple Intelligence formats it.
- If **you** choose a cloud provider and enter your own API key, KVoice
  asks you first, then sends that dictation's audio or text straight from
  your iPhone to that provider. Nothing goes through the developer.
- The KVoice keyboard sends nothing off your iPhone.

## What stays on your iPhone

- **Recordings.** Audio is recorded only while you dictate. While KVoice
  keeps the microphone ready for the keyboard (standby), nothing is
  recorded or saved until you start a dictation. By default a recording
  is kept in History so you can play it or transcribe it again. Turn off
  Settings › History › Keep audio recordings to delete each recording as
  soon as it is transcribed.
- **Transcripts and formatted text** are kept in History. Settings ›
  History › Keep history can limit this to 30 or 7 days, and Delete All
  History removes everything. Deleting KVoice deletes history, recordings,
  modes and settings.
- **Modes and settings** are stored in the app's shared container so the
  keyboard can read them.
- **API keys** you enter are stored in the iOS Keychain on your iPhone,
  never in files or settings, and are sent only to the provider they
  belong to. iOS keeps Keychain items after an app is deleted, so remove
  your keys in Settings before deleting KVoice if you want them gone.
- **A diagnostics log** (states and timings, not your words) stays on the
  device in Settings › About › Diagnostics. KVoice never uploads it.
- **The clipboard.** If Copy results automatically is on, finished text is
  copied to the clipboard on your iPhone.

## When data leaves your iPhone

Only in these cases, each started by you:

1. **Cloud transcription.** If you choose a cloud engine (OpenAI, Groq,
   Google AI Studio, Google Vertex AI or an OpenAI-compatible endpoint you
   enter), the audio of each dictation is sent to that provider.
2. **Cloud AI formatting.** If you choose a cloud AI provider (OpenAI,
   Anthropic, Google AI Studio, Google Vertex AI, Groq, OpenRouter or an
   OpenAI-compatible endpoint), the transcript and the mode's instructions
   are sent to that provider.
3. **Downloads.** Whisper models download from the WhisperKit model
   repository on Hugging Face, and Apple Speech language models download
   from Apple. These downloads send none of your dictation.

Before KVoice sends anything to a cloud provider for the first time, it
shows which provider and what will be sent, and asks for your permission.
If you decline, KVoice stays on device. The request uses your own API key,
so it is between you and that provider, and the provider's privacy policy
and terms apply to what it receives. KVoice does not share data with
anyone else.

## The keyboard

The KVoice keyboard types on your iPhone. Without Full Access it works as
a plain keyboard. With Full Access it can also talk to the KVoice app on
the same iPhone, to start a dictation and type the result. The keyboard
does not record audio, does not send anything over the network, and does
not keep or share what you type.

## Your choices

- **Withdraw consent.** Settings › Privacy › Stop Sending to *provider*
  withdraws your permission and moves KVoice back to on-device engines.
  You can also choose Apple Speech, Whisper or Apple Intelligence at any
  time.
- **Delete data.** Delete single dictations in History, use Delete All
  History, remove an API key in Settings (do this before deleting the app,
  as the Keychain keeps it), or delete the app.
- **Microphone and speech recognition** permissions can be changed in the
  iOS Settings app.

Because the developer never receives your data, there is nothing for the
developer to export or delete on a server. For data you sent to a cloud
provider, contact that provider.

## Children

KVoice is not directed at children and collects no data from anyone.

## Changes and contact

Changes to this policy are published in this file, with the date above.
Questions: open an issue at
https://github.com/kccarlos/kvoice-ios/issues (see [Support](Support.md)).
