# Dictation states

Every way to start or stop a dictation shares one record, `DictationActivity`
(KVoiceCore), stored in the App Group at `KVoice/Handoff/activity.json`. It
is the only authority on who owns the microphone. Only the app process
writes it, through the pure reducer `DictationActivityReducer`; each write is
atomic and posts the Darwin notification
`io.github.kccarlos.kvoice.ios.activity`. The keyboard and the widgets only
read it.

`HandoffAppState` (`app-state.json`, "the app takes keyboard commands") is a
projection of the record written next to it, and `HandoffResult`
(`result.json`) stays the per-session progress and text mailbox for the
keyboard: its `consumed` flag is what makes keyboard insertion happen exactly
once.

## Record

| Field | Meaning |
| --- | --- |
| `id` | The current dictation (keyboard session, app recording or shortcut run). |
| `phase` | See below. |
| `modeID` | The mode of the current dictation. |
| `jobs` | Accepted processing jobs, oldest (running) first. |
| `leaseExpiresAt` | Every non-idle phase has a lease; an expired lease reads as `idle`. |
| `updatedAt` | Last write. |

| Phase | Lease |
| --- | --- |
| `idle` | none |
| `standby(expiresAt)` | `expiresAt` (the "Keep listening for the keyboard" window) |
| `recording(owner: .app, source, startedAt)` | 2 min, renewed every 15 s while the app records |
| `recording(owner: .shortcut, source: .shortcut, startedAt)` | 15 min |
| `processing(stage, jobID)` | 60 s, renewed every 15 s while the job runs |
| `delivered(jobID)` / `failed(jobID, message)` | 2 min (the keyboard insert window), then idle |

An expired lease means the owner is gone (a cancelled shortcut, a killed
app): the phase reads as `idle` everywhere, so nothing can stay stuck.

`source` is `keyboard`, `app` (record button), `intent` (Siri, widget,
Control Center) or `shortcut`.

The keyboard also writes `keyboard.json` (`keyboardVisibleAt`) about every
2 s while it is on screen with Full Access, and clears it when it goes away.
The keyboard counts as visible while that heartbeat is under 5 s old. It
posts no notification.

## Transition table

Phases are read through the lease ("valid" below); an expired phase is
`idle`. `delivered` and `failed` behave like `idle` for every entry point
except the keyboard's auto-insert.

### Begin Dictation (shortcut gate, background)

| Phase | Result | Outcome |
| --- | --- | --- |
| idle, delivered, failed | `recording(.shortcut)`, lease 15 min | `.record` |
| standby | End standby (stop the engine, deactivate the audio session, keyboard commands off), then `recording(.shortcut)` | `.record` |
| recording(.app) | Stop and process that recording, exactly as tapping Stop (keyboard sessions still insert) | `.stoppedExisting`: the shortcut ends without recording, so the Action Button toggles |
| recording(.shortcut), lease valid | No change | `.alreadyRecording` (the shortcut's If skips recording; short dialog) |
| recording(.shortcut), lease expired | Same as idle | `.record` |
| processing | `recording(.shortcut)`; the running job continues and later jobs queue behind it | `.record` |

The optional Mode parameter becomes the active mode and the record's
`modeID`.

### Transcribe Audio (background)

| Phase | Result |
| --- | --- |
| recording(.shortcut) (gated run) | The job takes the record's `id` and mode; `recording(.shortcut)` is cleared: `processing(transcribing)`, or queued behind a running job |
| idle, standby, delivered, failed (ungated run) | New job id, active mode; `processing(transcribing)` |
| recording(.app) | Job queued; the phase stays `recording(.app)` (the app owns the microphone) |
| processing | Job queued (FIFO); the phase keeps showing the running job |

Steps of a job:

1. Save the audio in `Recordings/` and add a pending history record.
2. Convert it to 16 kHz mono WAV (`AVAudioConverter`). The pending record
   then points at the WAV.
3. Silent or empty audio: `failed(noSpeech)`, the record and audio are
   removed, the intent throws "No speech detected." so the shortcut stops and
   nothing is copied.
4. Background budget (about 30 s, 25 s used): estimate the cost. On-device
   Whisper with the model not loaded, or audio over 60 s, cannot run in
   the background: use Apple Speech for this job when its assets are
   installed for the language, otherwise continue in the foreground (the app
   opens and finishes the job). The same applies to any engine whose estimate
   (transcription plus 6 s for AI formatting) is over the budget.
5. Run through the pipeline's serial job queue (one job at a time).
6. Finish: the record is completed (or marked failed, audio kept); the phase
   becomes `delivered(jobID)` or `failed(jobID, message)` unless a recording
   owns the microphone or another job is queued (then the next job runs);
   `HandoffResult(jobID, done, text)` is written; the text is returned to the
   shortcut, which copies it.

The `HandoffResult` of a shortcut job (and of any dictation not started from
the keyboard) is written only when the keyboard is visible (heartbeat under
5 s) and the device is unlocked (`KeyboardInsertion.decide`); otherwise
nothing is written, so a keyboard opened later never types it (while locked
insertion is "not applicable"). A visible keyboard auto-inserts it once and
marks it consumed. Keyboard sessions always write their result, as before.

While a background job runs, a local notification is scheduled 40 s ahead
and cancelled when the job ends. If the system kills the intent, the
notification says the dictation was saved, and the pending record is
resumed the next time KVoice becomes active. Audio is never deleted before
a job finishes, except silence.

### KVoice keyboard mic

| Phase | Result |
| --- | --- |
| idle, delivered, failed | Open KVoice (`HandoffRequest` + `kvoice://dictate?session=`) |
| standby, lease valid | `HandoffCommand(.start)`, no app switch |
| recording(.app) | `HandoffCommand(.stop)` for the record's `id`; the keyboard follows that session and types its result (also for a recording started in the app) |
| recording(.shortcut) | Mic disabled. Status: "Recording with the Action Button — tap Stop in the recording panel" |
| processing | Mic disabled; the status shows the stage |
| delivered (on appear or on change) | Type the result if unconsumed and under 2 min old, then mark it consumed |

### App record button, DictateIntent (Siri, widget, Control Center)

Same as the keyboard, but the app is in front, so it records itself.

| Phase | Result |
| --- | --- |
| idle, delivered, failed | `recording(.app)` and record |
| standby | `recording(.app)`; the running engine records |
| recording(.app) | Stop and process (record button, DictateIntent toggle, StopDictationIntent) |
| recording(.shortcut) | Do not start; show "Recording with the Action Button" (Shortcuts owns the microphone), with a Reset action for an abandoned run |
| processing | Do not start ("KVoice is still working on the previous dictation.") |

A keyboard request that arrives while another keyboard session is
recording replaces it (the keyboard moved on), as before.

### Audio interruptions

Phone call, Siri, another app (including Shortcuts' Record Audio) taking the
microphone, media services reset, or a route change that stops the engine:

| Phase | Result |
| --- | --- |
| recording(.app), at least 1 s captured | Stop and process the audio so far (same as Stop) |
| recording(.app), under 1 s | Cancel; idle |
| standby | End standby quietly (not an error); keyboard commands off; idle |
| any other | No change |

### App launch

| Phase left by the last process | Result |
| --- | --- |
| standby, recording(.app), processing | Idle (that process is gone; its jobs are resumed from pending history records) |
| recording(.shortcut), lease valid | Kept (Shortcuts owns it) |
| delivered, failed | Kept until the lease ends |

When the app becomes active it resumes pending history records that no job
in this process is running.

### Manual reset

The Action Button settings screen and the app's "Recording with the Action
Button" notice offer Reset: `recording(.shortcut)` becomes idle. This covers a
shortcut stopped from the recording panel before its lease ends.

## Locked device

Transcribe Audio works after the first unlock: Keychain items use
`AfterFirstUnlock`, and App Group files (`Handoff/`, `Recordings/`) are
written with `completeUntilFirstUserAuthentication`. Saving to history and
returning the text work; keyboard insertion is not applicable while locked.
