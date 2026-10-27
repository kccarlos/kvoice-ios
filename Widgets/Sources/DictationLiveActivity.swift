import ActivityKit
import AppIntents
import KVoiceCore
import SwiftUI
import WidgetKit

/// The Live Activity shown while a Toggle Dictation (or an app recording)
/// records and processes: Lock Screen, Dynamic Island, and a Stop button.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            DictationLockScreenView(status: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.modeName, systemImage: context.state.modeIcon)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if case .recording = context.state.stage {
                        StopButton()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StageLine(status: context.state)
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                if case .recording(let startedAt) = context.state.stage {
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 48)
                } else {
                    Image(systemName: stageIcon(context.state.stage))
                }
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
        }
    }
}

private func stageIcon(_ stage: DictationLiveStatus.Stage) -> String {
    switch stage {
    case .recording: "mic.fill"
    case .transcribing: "waveform"
    case .formatting: "sparkles"
    case .done: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
}

private struct DictationLockScreenView: View {
    let status: DictationLiveStatus

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: stageIcon(status.stage))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Label(status.modeName, systemImage: status.modeIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                StageLine(status: status)
            }
            Spacer(minLength: 0)
            if case .recording = status.stage {
                StopButton()
            }
        }
    }
}

/// The main line: timer, stage name, result preview or failure.
private struct StageLine: View {
    let status: DictationLiveStatus

    var body: some View {
        switch status.stage {
        case .recording(let startedAt):
            HStack(spacing: 6) {
                Text("Recording").font(.headline)
                Text(startedAt, style: .timer).font(.headline).monospacedDigit().foregroundStyle(.secondary)
            }
        case .transcribing:
            Text("Transcribing…").font(.headline)
        case .formatting:
            Text("Formatting…").font(.headline)
        case .done(let preview):
            VStack(alignment: .leading, spacing: 2) {
                Text("Copied").font(.headline)
                if !preview.isEmpty {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictation failed").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: ToggleDictationIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}

// MARK: - Control

/// A Control Center / Lock Screen / Action Button control: one press starts
/// dictating in the background, the next stops and copies the text.
struct ToggleDictationControl: ControlWidget {
    static let kind = "io.github.kccarlos.kvoice.ios.widgets.toggle-dictation-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("Toggle Dictation", systemImage: "waveform")
            }
        }
        .displayName("Toggle Dictation")
        .description("Press to start dictating, press again to stop and copy the text.")
    }
}
