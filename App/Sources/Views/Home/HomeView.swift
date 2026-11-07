import KVoiceKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppPreferences.autoCopyKey, store: AppPreferences.store) private var autoCopy = true
    @State private var levels = WaveformView.silentLevels
    @State private var rerunError: String?
    @State private var isRerunning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        ModeChips()
                        if model.needsAISetup(model.modes.activeMode) {
                            Button("Needs AI setup", systemImage: "exclamationmark.triangle") { model.openAISettings() }
                                .font(.subheadline)
                                .tint(.orange)
                        }
                    }
                    recorder
                    if let result = model.currentResult, !model.pipeline.isBusy {
                        ResultCard(
                            result: result,
                            isRerunning: isRerunning,
                            onRerun: { mode in rerun(result, with: mode) }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !model.pipeline.isBusy {
                        howTo
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .animation(.smooth, value: model.currentResult?.record.id)
                .animation(.smooth, value: model.pipeline.isBusy)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("KVoice")
            .task(id: model.historyRevision) { await showLatest() }
            .onChange(of: model.pipeline.level) { _, level in
                levels.removeFirst()
                levels.append(CGFloat(level))
            }
            .onChange(of: model.isRecording) { _, recording in
                if !recording { withAnimation(.smooth) { levels = WaveformView.silentLevels } }
            }
            .alert("Re-run failed", isPresented: Binding(get: { rerunError != nil }, set: { if !$0 { rerunError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(rerunError ?? "")
            }
        }
    }

    private var recorder: some View {
        VStack(spacing: 20) {
            RecordButton(
                isRecording: model.isRecording,
                isBusy: model.pipeline.isBusy && !model.isRecording,
                level: CGFloat(model.pipeline.level),
                onStart: { Task { await model.startDictation() } },
                onStop: { Task { await model.stopDictation() } }
            )

            // Below the button, so the button never moves under a finger; at
            // rest it takes no room and the result card's actions fit.
            if model.isRecording {
                WaveformView(levels: levels, isActive: true)
                    .frame(height: 64)
            }

            PhaseStatus(autoCopy: autoCopy)
                .frame(minHeight: 44, alignment: .top)

            if model.pipeline.isBusy {
                Button("Cancel", role: .cancel) { model.cancelDictation() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// When there is no result to show: a two-line how-to.
    private var howTo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pick a mode. Dictation types what you say; AI modes tidy it up.", systemImage: "square.stack.3d.up")
            Label("Your text appears here, ready to copy or share.", systemImage: "doc.on.doc")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    /// Shows the latest history record when there is no current result (or
    /// it was deleted), so the last text is one tap from Copy.
    private func showLatest() async {
        guard let history = model.history else { return }
        if let current = model.currentResult, (try? await history.record(id: current.record.id)) != nil { return }
        let latest = (try? await history.all(limit: 1))?.first
        model.currentResult = latest.flatMap { $0.status == .done ? DictationResult(record: $0) : nil }
    }

    private func rerun(_ result: DictationResult, with mode: Mode) {
        isRerunning = true
        Task {
            defer { isRerunning = false }
            do {
                try await model.rerun(result.record, with: mode, preferAudio: false)
            } catch {
                rerunError = error.localizedDescription
            }
        }
    }
}

/// What the pipeline is doing, in words.
struct PhaseStatus: View {
    @Environment(AppModel.self) private var model
    let autoCopy: Bool

    var body: some View {
        Group {
            switch model.pipeline.phase {
            case .idle:
                if model.handoff.effectivePhase.recordingOwner == .shortcut {
                    // Shortcuts' Record Audio owns the microphone.
                    VStack(spacing: 8) {
                        Label(DictationActivity.Message.shortcutRecordingApp, systemImage: "button.vertical.right.press")
                            .foregroundStyle(.orange)
                        Button("Not recording? Reset") { model.handoff.resetShortcut() }
                            .font(.footnote)
                    }
                } else if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Hold to talk, or tap to start and stop.")
                        .foregroundStyle(.secondary)
                }
            case .recording:
                Label("Listening in \(model.pipeline.recordingMode?.name ?? model.modes.activeMode.name)",
                      systemImage: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            case .transcribing:
                HStack(spacing: 8) { ProgressView(); Text("Transcribing…") }
            case .formatting:
                HStack(spacing: 8) { ProgressView(); Text("Formatting…") }
            case .done:
                Label(autoCopy ? "Done · copied to the clipboard" : "Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .contentTransition(.opacity)
        .animation(.smooth, value: model.pipeline.phase)
    }
}
