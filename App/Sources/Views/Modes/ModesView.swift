import KVoiceKit
import SwiftUI

struct ModesView: View {
    @Environment(AppModel.self) private var model
    @State private var newMode: Mode?
    @State private var confirmingReset = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.modes.modes) { mode in
                        NavigationLink(value: mode.id) {
                            ModeRow(mode: mode, isActive: mode.id == model.modes.activeModeID)
                        }
                        .swipeActions(edge: .leading) {
                            Button("Use", systemImage: "checkmark.circle") {
                                try? model.modes.setActiveMode(id: mode.id)
                            }
                            .tint(.accentColor)
                        }
                        .deleteDisabled(mode.isBuiltIn)
                    }
                    .onMove { source, destination in
                        perform { try model.modes.move(fromOffsets: source, toOffset: destination) }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { model.modes.modes[$0].id }
                        perform { for id in ids { try model.modes.delete(id: id) } }
                    }
                } footer: {
                    Text("Modes turn what you say into a finished format. Swipe right to make a mode active; built-in modes can be edited and reset.")
                }

                Section {
                    Button("Reset Built-in Modes", systemImage: "arrow.counterclockwise", role: .destructive) {
                        confirmingReset = true
                    }
                }
            }
            .navigationTitle("Modes")
            .navigationDestination(for: UUID.self) { id in
                if let mode = model.modes.mode(id: id) {
                    ModeEditorView(mode: mode, isNew: false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Mode", systemImage: "plus") {
                        newMode = Mode(name: "", icon: "text.bubble", instructions: "")
                    }
                }
            }
            .sheet(item: $newMode) { mode in
                NavigationStack {
                    ModeEditorView(mode: mode, isNew: true)
                }
            }
            .confirmationDialog(
                "Reset built-in modes?", isPresented: $confirmingReset, titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { perform { try model.modes.resetBuiltIns() } }
            } message: {
                Text("Your edits to the built-in modes are replaced with the originals. Custom modes are kept.")
            }
            .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

struct ModeRow: View {
    let mode: Mode
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: mode.icon)
                .font(.title3)
                .foregroundStyle(isActive ? Color.white : Color.accentColor)
                .frame(width: 40, height: 40)
                .background(isActive ? Color.accentColor : Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.name).font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isActive {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [mode.usesAI ? "AI" : "Plain dictation"]
        parts.append(mode.language.map(LanguageOptions.name(for:)) ?? "Any language")
        if mode.translateToEnglish { parts.append("to English") }
        if !mode.isBuiltIn { parts.append("Custom") }
        return parts.joined(separator: " · ")
    }
}
