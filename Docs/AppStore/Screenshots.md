# App Store screenshots

KVoice is iPhone only, so only iPhone sizes are needed (Apple's screenshot
specifications, App Store Connect Help):

| Size class | Pixels (portrait) | Simulator | Status |
| --- | --- | --- | --- |
| iPhone with Dynamic Island, medium display | 1206 × 2622 | iPhone 18 Pro (the tour's simulator) | Required |
| iPhone with Dynamic Island, large display ("6.9-inch") | 1320 × 2868 | iPhone 18 Pro Max | Recommended; otherwise the 6.5-inch set is scaled |
| iPhone with Face ID, large display ("6.5-inch") | 1284 × 2778 | iPhone 13 Pro Max class | Only if no large Dynamic Island set |

Up to 10 PNG or JPEG files per size, no transparency. Use plain captures
of the app, no marketing frames.

## Which screens

Capture from the screenshot tour (`Scripts/dev/tour.sh sim <run>`, demo
data from `-kvoiceDemo`, light appearance). For the large size, run the
tour on an iPhone 18 Pro Max simulator. Order:

1. `10-home-idle`: Dictate tab with modes and the latest result.
2. `12-home-recording`: recording with the waveform.
3. `56-keyboard-fullAccessCard` or `50-keyboard-letters`: the keyboard.
4. `20-modes-list`: modes.
5. `21-modeeditor-custom`: a custom mode with its instructions.
6. `30-history-list`: history.
7. `31-historydetail-formatted`: a dictation with Formatted / Transcript.
8. `61-settings-transcription`: on-device engines (privacy story).
9. `40-handoff-stopped` (optional): the keyboard dictation screen.

Optionally add a dark-appearance Home shot (`dark/10-home-idle`). Before
uploading, check that the status bar shows no personal carrier name and
that no real dictation appears (the demo data is fictional).
