# KVoice support

KVoice is a voice dictation app for iPhone. It is free and open source.

## Get help

Open an issue at https://github.com/kccarlos/kvoice-ios/issues. Describe
what you did, what you expected and what happened, and include your iPhone
model, iOS version and the KVoice version (Settings › About). Do not post
API keys or dictation you want to keep private.

## Common questions

**How do I dictate?** Open KVoice, pick a mode, then hold the microphone
to talk or tap to start and tap again to stop. The text appears below it,
ready to copy or share.

**Do I need an account or an API key?** No. KVoice works on device with
Apple Speech or Whisper, and Apple Intelligence where your iPhone supports
it. API keys are only for cloud providers you choose yourself.

**How do I add the keyboard?** Settings app › General › Keyboard ›
Keyboards › Add New Keyboard… › KVoice. For dictation from the keyboard,
tap KVoice there and turn on Allow Full Access. Typing works without it.

**Why does the keyboard open KVoice?** iOS keyboards cannot use the
microphone, so the KVoice app records for them. Tap the microphone in the
keyboard, KVoice opens and listens, swipe back to your app, and the text is
typed where you left off. For a few minutes afterwards the keyboard can
start the next dictation without switching apps (Settings › Keep listening
for the keyboard; choose Off to turn this off).

**Why is the microphone indicator on?** KVoice is recording, or it is
keeping the microphone ready for the keyboard after a keyboard dictation.
End it from the Live Activity or set Keep listening for the keyboard to
Off.

**An AI mode says "Needs AI setup".** The mode's AI provider cannot run:
Apple Intelligence is off or not supported, or a cloud provider has no API
key. Fix it in Settings › AI formatting, or use Dictation mode.

**How do I stop sending data to a cloud provider?** Settings › Privacy ›
Stop Sending to *provider*. See the [privacy policy](Privacy.md).

**How do I delete my data?** Settings › History › Delete All History, or
delete the app. Remove API keys in Settings first: iOS keeps Keychain
items after an app is deleted. Nothing is stored anywhere else.
