import KVoiceKit
import SwiftUI
import UIKit

struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var record: HistoryRecord
    @State private var showsRaw = false
    @State private var player = AudioPlayer()
    @State private var isRerunning = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var copied = false

    init(record: HistoryRecord) {
        _record = State(initialValue: record)
    }

    private var audioURL: URL? { model.history?.audioURL(for: record) }
    private var text: String { showsRaw ? record.rawTranscript : record.formattedText }
    private var hasDistinctRaw: Bool { record.rawTranscript != record.formattedText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if hasDistinctRaw {
                    Picker("Version", selection: $showsRaw) {
                        Text("Formatted").tag(false)
                        Text("Transcript").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .redacted(reason: isRerunning ? .placeholder : [])

                if let audioURL {
                    AudioPlayerBar(player: player, url: audioURL, duration: record.duration)
                }

                details
            }
            .padding()
        }
        .navigationTitle(record.modeName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: text)
                Spacer()
                rerunMenu
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .onDisappear { player.stop() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
        .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    player.stop()
                    try? await model.history?.delete(id: record.id)
                    model.historyChanged()
                    dismiss()
                }
            }
        }
        .alert("Re-run failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var rerunMenu: some View {
        Menu {
            Section("Reformat the transcript with") {
                ForEach(model.modes.modes) { mode in
                    Button { rerun(mode, preferAudio: false) } label: { Label(mode.name, systemImage: mode.icon) }
                }
            }
            if audioURL != nil {
                Section("Transcribe the audio again with") {
                    ForEach(model.modes.modes) { mode in
                        Button { rerun(mode, preferAudio: true) } label: { Label(mode.name, systemImage: mode.icon) }
                    }
                }
            }
        } label: {
            Label("Re-run", systemImage: "arrow.trianglehead.2.clockwise")
        }
        .disabled(isRerunning || model.pipeline.isBusy)
    }

    private var details: some View {
        VStack(spacing: 0) {
            DetailRow(title: "Date", value: record.date.formatted(date: .abbreviated, time: .shortened))
            DetailRow(title: "Length", value: Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
            DetailRow(title: "Engine", value: record.engine)
            if let provider = record.provider { DetailRow(title: "AI", value: provider) }
            DetailRow(title: "Audio", value: audioURL == nil ? "Not kept" : "Kept on this device")
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func rerun(_ mode: Mode, preferAudio: Bool) {
        isRerunning = true
        player.stop()
        Task {
            defer { isRerunning = false }
            do {
                let result = try await model.rerun(record, with: mode, preferAudio: preferAudio)
                record = result.record
                showsRaw = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
    }
}
