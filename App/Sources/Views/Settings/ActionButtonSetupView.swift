import KVoiceKit
import SwiftUI

/// The published "KVoice Dictation" shortcut (an iCloud shortcut link).
/// Empty until it is published; the setup screen then shows manual steps.
enum KVoiceShortcutLink {
    static let url = ""
}

/// Settings › Action Button: how to set up the dictation shortcut, and a
/// debug view of the shared dictation state.
struct ActionButtonSetupView: View {
    var body: some View {
        List {
            Section {
                ActionButtonExplainer()
            }
            Section {
                ToggleSetupSteps()
            } header: {
                Text("Set up")
            } footer: {
                Text("Control Center and the Lock Screen can also hold the Toggle Dictation control.")
            }
            Section {
                DisclosureGroup("Advanced: Record Audio shortcut") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A manual shortcut that records with the Shortcuts app instead. Use it only if Toggle Dictation does not work for you.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ActionButtonSetupSteps()
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                ActionButtonStateTester()
            } header: {
                Text("Test")
            } footer: {
                Text("Shows what Begin Dictation (the advanced shortcut) would answer now, without starting anything.")
            }
        }
        .navigationTitle("Action Button")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { JobNotifier.requestAuthorization() }
    }
}

struct ActionButtonExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dictate from any app", systemImage: "button.vertical.right.press")
                .font(.headline)
            Text("Press the Action Button once to start recording and again to stop. KVoice transcribes, copies the text to the clipboard, and types it when the KVoice keyboard is open. Everything is saved in History.")
            Text("In any app with the KVoice keyboard open: press the Action Button, speak, press again, and the text is typed. The keyboard mic then works without leaving the app while KVoice keeps listening (see Keep listening for the keyboard in Settings). Tap ⏻ on the keyboard, or End in the Live Activity, to end the session.")
            Text("KVoice tries to start in the background so the app you're in stays in front. If iOS refuses, KVoice opens briefly to start (on the Lock Screen it asks for Face ID) and you can switch back. A Live Activity shows the recording; its Stop button does the same as the second press.")
                .foregroundStyle(.secondary)
            Text("Long recordings, or a mode that needs more time than iOS gives a background task, finish in KVoice instead: you are asked to open it when you stop.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}

/// The one-step setup: pick Toggle Dictation in the Action Button settings.
struct ToggleSetupSteps: View {
    static let steps: [String] = [
        "Open Settings › Action Button.",
        "Swipe to Controls, tap the control and choose KVoice › Toggle Dictation. Or swipe to Shortcut and choose KVoice › Toggle Dictation.",
        "Press the Action Button to start dictating, and press it again to stop. The text is copied."
    ]

    var body: some View {
        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
            StepRow(number: index + 1, text: step)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: .circle)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text).font(.callout)
        }
    }
}

struct ActionButtonSetupSteps: View {
    @Environment(\.openURL) private var openURL

    static let manualSteps: [String] = [
        "Open the Shortcuts app and tap + to create a shortcut.",
        "Add KVoice › Begin Dictation.",
        "Add If, and set it to: Outcome is Record.",
        "Inside the If, add Record Audio. Set Start to Immediately and Finish to On Tap.",
        "Below it, add KVoice › Transcribe Audio with Audio set to Recorded Audio. Mode is optional.",
        "Below it, add Copy to Clipboard. End If closes the block.",
        "Name the shortcut, then open Settings › Action Button, choose Shortcut and pick it."
    ]

    var body: some View {
        if let url = URL(string: KVoiceShortcutLink.url), !KVoiceShortcutLink.url.isEmpty {
            Button("Add Shortcut", systemImage: "plus.app") { openURL(url) }
            Text("Then open Settings › Action Button, choose Shortcut and pick it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(Self.manualSteps.enumerated()), id: \.offset) { index, step in
                StepRow(number: index + 1, text: step)
            }
        }
    }
}

/// The current shared state and the gate's answer, for debugging.
struct ActionButtonStateTester: View {
    @Environment(AppModel.self) private var model
    @State private var answer: String?

    var body: some View {
        let handoff: HandoffCoordinator = model.handoff
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LabeledContent("State", value: Self.describe(handoff.activity.effectivePhase(now: context.date)))
        }
        if let answer {
            LabeledContent("Begin Dictation would answer", value: answer)
        }
        Button("Test", systemImage: "play.circle") {
            answer = DictationGateOutcome(handoff.previewGate()).displayName
        }
        if handoff.effectivePhase.recordingOwner == .shortcut {
            Button("Reset Action Button Recording", systemImage: "arrow.counterclockwise", role: .destructive) {
                handoff.resetShortcut()
                answer = nil
            }
        }
    }

    static func describe(_ phase: DictationActivity.Phase) -> String {
        switch phase {
        case .idle: "Idle"
        case .standby(let until): "Listening for the keyboard until \(until.formatted(date: .omitted, time: .shortened))"
        case .recording(.app, let source, _): "Recording in KVoice (\(source.rawValue))"
        case .recording(.shortcut, _, _): "Recording with the Action Button"
        case .processing(.transcribing, _): "Transcribing"
        case .processing(.formatting, _): "Formatting"
        case .delivered: "Delivered"
        case .failed(_, let message): "Failed: \(message)"
        }
    }
}

extension DictationGateOutcome {
    var displayName: String {
        switch self {
        case .record: "Record"
        case .stoppedExisting: "Stopped Existing"
        case .alreadyRecording: "Already Recording"
        }
    }
}
