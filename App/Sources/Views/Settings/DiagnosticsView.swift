import KVoiceKit
import SwiftUI

/// The on-device diagnostics log (no transcripts or keys, only lengths and
/// flags) and the Toggle Dictation start strategy, for TestFlight testing.
struct DiagnosticsView: View {
    @State private var entries: [DiagnosticsLog.Entry] = []
    @State private var strategy = ToggleStartStrategy.current()

    var body: some View {
        List {
            Section {
                Picker("Start strategy", selection: $strategy) {
                    Text("Return immediately").tag(ToggleStartStrategy.returnImmediately)
                    Text("Hold until stopped").tag(ToggleStartStrategy.holdUntilStopped)
                }
                .onChange(of: strategy) { _, value in ToggleStartStrategy.set(value) }
            } header: {
                Text("Toggle Dictation")
            } footer: {
                Text("Hold until stopped keeps the shortcut running while it records, in case iOS only lends the microphone to a running shortcut.")
            }

            Section("Log, newest first") {
                if entries.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.category) · \(entry.date.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.message).font(.callout.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Copy All", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = entries.map(Self.line).joined(separator: "\n")
                }
                Button("Clear", systemImage: "trash", role: .destructive) {
                    DiagnosticsLog.shared.clear()
                    reload()
                }
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        entries = DiagnosticsLog.shared.read().reversed()
    }

    private static func line(_ entry: DiagnosticsLog.Entry) -> String {
        "\(entry.date.formatted(.iso8601)) [\(entry.category)] \(entry.message)"
    }
}
