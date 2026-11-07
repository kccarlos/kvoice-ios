import KVoiceKit
import SwiftUI

/// The published "KVoice Dictation" shortcut (an iCloud shortcut link).
/// Empty until it is published; the setup screen then shows manual steps.
enum KVoiceShortcutLink {
    static let url = ""
}

/// Settings › Action Button (Control Center and Back Tap on iPhones
/// without one): how to set up Toggle Dictation.
struct ActionButtonSetupView: View {
    var body: some View {
        List {
            Section {
                ActionButtonExplainer()
            }
            Section("Set up") {
                ToggleSetupSteps()
            }
            Section {
                DisclosureGroup("If Toggle Dictation does not work") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Make a shortcut that records with the Shortcuts app instead:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ActionButtonSetupSteps()
                    }
                    .padding(.vertical, 4)
                }
            }
            #if DEBUG
            Section("Debug") {
                ActionButtonStateTester()
            }
            #endif
        }
        .navigationTitle(DeviceModel.hasActionButton() ? "Action Button" : "Controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { JobNotifier.requestAuthorization() }
    }
}

struct ActionButtonExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dictate from any app", systemImage: "button.vertical.right.press")
                .font(.headline)
            if DeviceModel.hasActionButton() {
                Text("Press the Action Button to start, and press it again to stop. The text is copied, and typed for you when the KVoice keyboard is open.")
            } else {
                Text("This iPhone has no Action Button. Put Toggle Dictation in Control Center, on the Lock Screen or on Back Tap: tap once to start, again to stop. The text is copied, and typed for you when the KVoice keyboard is open.")
            }
            Text("KVoice may open for a moment to start listening. Switch back and keep going.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}

/// Where to put the Toggle Dictation control.
struct ToggleSetupSteps: View {
    static let actionButtonSteps: [String] = [
        "Open Settings › Action Button.",
        "Swipe to Controls and choose KVoice › Toggle Dictation.",
        "Press once to start dictating, and again to stop. Control Center and the Lock Screen can hold it too."
    ]
    static let otherSteps: [String] = [
        "Control Center: touch and hold an empty spot, tap Add a Control and choose Toggle Dictation.",
        "Lock Screen: touch and hold it, tap Customize › Lock Screen, tap a control at the bottom and choose Toggle Dictation.",
        "Back Tap: in Shortcuts, make a shortcut with KVoice › Toggle Dictation, then pick it in Settings › Accessibility › Touch › Back Tap."
    ]

    var body: some View {
        let steps = DeviceModel.hasActionButton() ? Self.actionButtonSteps : Self.otherSteps
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
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

#if DEBUG
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

#endif

extension DictationGateOutcome {
    var displayName: String {
        switch self {
        case .record: "Record"
        case .stoppedExisting: "Stopped Existing"
        case .alreadyRecording: "Already Recording"
        }
    }
}
