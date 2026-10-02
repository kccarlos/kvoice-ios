import KVoiceKit
import SwiftUI
import UIKit

/// The latest result with Copy, Share and Re-run.
struct ResultCard: View {
    @Environment(AppModel.self) private var model
    let result: DictationResult
    let isRerunning: Bool
    let onRerun: (Mode) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(result.record.modeName, systemImage: modeIcon)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(result.record.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = result.formattingError {
                Label("AI formatting failed, showing the transcript. \(error.localizedDescription)",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Text(result.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .redacted(reason: isRerunning ? .placeholder : [])

            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = result.text
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.glassProminent)

                ShareLink(item: result.text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)

                Spacer(minLength: 0)

                RerunMenu(disabled: isRerunning, onRerun: onRerun)
                    .buttonStyle(.glass)
            }
            .controlSize(.regular)
            .labelStyle(.titleAndIcon)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onChange(of: result.record.id) { copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var modeIcon: String {
        result.record.modeID.flatMap(model.modes.mode(id:))?.icon ?? "text.bubble"
    }

    private var details: String {
        var parts = [result.record.engine]
        if let provider = result.record.provider { parts.append(provider) }
        parts.append(Duration.seconds(result.record.duration).formatted(.time(pattern: .minuteSecond)))
        return parts.joined(separator: " · ")
    }
}

/// "Re-run with another mode".
struct RerunMenu: View {
    @Environment(AppModel.self) private var model
    var title = "Re-run"
    let disabled: Bool
    let onRerun: (Mode) -> Void

    var body: some View {
        Menu {
            Section("Re-run with") {
                ForEach(model.modes.modes) { mode in
                    Button { onRerun(mode) } label: {
                        Label(mode.name, systemImage: mode.icon)
                    }
                }
            }
        } label: {
            Label(title, systemImage: "arrow.trianglehead.2.clockwise")
        }
        .disabled(disabled)
    }
}
