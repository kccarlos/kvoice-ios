# Notes for App Review

Paste the text below into App Store Connect › App Review Information ›
Notes. No sign-in is required, so leave the demo account empty.

---

KVoice is a voice dictation app with its own keyboard. There is no
account and no login, and it needs no API key: by default speech is turned
into text on device with Apple Speech, and AI modes use Apple Intelligence
on device where available (otherwise KVoice uses the plain Dictation mode).

**Try it in the app (about 1 minute)**
1. Open KVoice and finish the short welcome (allow the microphone).
2. On the Dictate tab, hold the microphone button and speak, or tap once to
   start and again to stop. The text appears below with Copy, Share and
   Re-run. Past dictations are in History.
3. Modes (Clean up, Message, Email, ...) change how the text is formatted.

**Keyboard (Settings › General › Keyboard › Keyboards › Add New Keyboard…
› KVoice)**
- The keyboard types English (QWERTY, numbers, symbols) and works without
  Full Access. The globe key switches to the next keyboard.
- Full Access is used only for dictation: it lets the keyboard exchange
  the dictated text and the mode list with the KVoice app through the
  shared App Group container on the same iPhone. The keyboard sends nothing
  over the network and does not store what is typed.
- Why the keyboard opens KVoice: iOS does not allow keyboard extensions to
  use the microphone. When the user taps the keyboard's microphone, the
  keyboard opens its own containing app, KVoice (never any other app),
  which records. The user swipes back and the text is typed where they left
  off. This happens only on that explicit tap. Technically, the keyboard
  asks the system to open KVoice's own URL scheme (kvoice://) through the
  UIApplication in its responder chain; it never opens other apps or URLs.

**Background audio (UIBackgroundModes: audio)**
- Recording continues while the user switches apps: a dictation started
  from the keyboard, Control Center, a Lock Screen widget, the Action
  Button or a Live Activity keeps recording until the user stops it from
  the Live Activity, the keyboard or the app.
- After a keyboard dictation, KVoice keeps the microphone ready for a few
  minutes (default 5, Settings › Keep listening for the keyboard, Off
  available) so the keyboard can start the next dictation without switching
  apps. The microphone indicator and a Live Activity are shown the whole
  time, and the user can end it from the Live Activity.
- KVoice does not play or record audio in the background for any other
  purpose.

**Live Activity:** shows the recording or processing state, the elapsed
time and a Stop/End button while a dictation or the standby is active.

**Cloud providers (optional):** users can enter their own API key for
OpenAI, Anthropic, Google AI Studio, Google Vertex AI, Groq, OpenRouter or
an OpenAI-compatible endpoint. Before anything is sent to such a provider
for the first time, KVoice shows a consent sheet naming the provider and
what is sent (audio for transcription, transcript text for formatting).
Declining keeps KVoice on device; consent can be withdrawn in Settings ›
Privacy. To see the sheet: Settings › Transcription › Cloud (your key).

**Data:** KVoice has no servers, analytics or ads. Recordings, history and
settings stay on the device; API keys are in the Keychain.
