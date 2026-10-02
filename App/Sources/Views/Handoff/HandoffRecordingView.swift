import KVoiceKit
import SwiftUI

/// Shown when the keyboard opens KVoice to dictate: recording has started,
/// the user swipes back to their app (or stops here).
struct HandoffRecordingView: View {
    @Environment(AppModel.self) private var model
    @State private var levels = WaveformView.silentLevels

    var body: some View {
        let pipeline = model.pipeline
        VStack(spacing: 28) {
            Spacer()

            Label(pipeline.recordingMode?.name ?? model.modes.activeMode.name,
                  systemImage: pipeline.recordingMode?.icon ?? model.modes.activeMode.icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)

            VStack(spacing: 10) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            WaveformView(levels: levels, isActive: model.isRecording)
                .frame(height: 72)
                .padding(.horizontal, 32)

            if model.isRecording {
                swipeBackHint
            }

            Spacer()

            controls
                .padding(.bottom, 24)
        }
        .padding()
        .onChange(of: pipeline.level) { _, level in
            levels.removeFirst()
            levels.append(CGFloat(level))
        }
        .animation(.smooth, value: pipeline.phase)
    }

    private var title: String {
        switch model.pipeline.phase {
        case .recording: "Recording"
        case .transcribing: "Transcribing…"
        case .formatting: "Formatting…"
        case .done: "Done"
        case .failed: "Something went wrong"
        case .idle: "Stopped"
        }
    }

    private var subtitle: String {
        switch model.pipeline.phase {
        case .recording: "Swipe back to your app and keep talking. Tap stop in the keyboard or here when you're done."
        case .transcribing, .formatting: "The text will be typed into your app."
        case .done: "Go back to your app: the KVoice keyboard types the text."
        case .failed(let error): error.localizedDescription
        case .idle: "Nothing was recorded."
        }
    }

    private var swipeBackHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
            Text("Swipe right along the bottom edge, or tap the back button at the top left")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var controls: some View {
        let pipeline = model.pipeline
        if model.isRecording {
            VStack(spacing: 16) {
                Button {
                    Task { await model.stopDictation() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                .accessibilityLabel("Stop dictation")

                Button("Cancel", role: .cancel) { model.cancelDictation() }
                    .buttonStyle(.glass)
            }
        } else if pipeline.isBusy {
            ProgressView().controlSize(.large)
        } else {
            Button("Close") { model.handoff.isPresentingRecorder = false }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }
}
