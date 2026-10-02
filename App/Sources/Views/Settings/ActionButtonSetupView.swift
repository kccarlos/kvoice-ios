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
                ActionButtonSetupSteps()
            } header: {
                Text("Set up")
            }
            Section {
                ActionButtonStateTester()
            } header: {
                Text("Test")
            } footer: {
                Text("Shows what Begin Dictation would answer now, without starting anything.")
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
            Text("Press the Action Button to start recording without leaving the app you're in, and tap Stop when you're done. KVoice transcribes in the background.")
            Text("The result is copied to the clipboard, and typed automatically when the KVoice keyboard is open. Everything is saved in History.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 4)
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
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: .circle)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    Text(step).font(.callout)
                }
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
