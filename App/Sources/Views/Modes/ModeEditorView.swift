import KVoiceKit
import SwiftUI

struct ModeEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Mode
    @State private var showingSymbols = false
    @State private var errorMessage: String?
    let isNew: Bool

    init(mode: Mode, isNew: Bool) {
        _draft = State(initialValue: mode)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Button {
                        showingSymbols = true
                    } label: {
                        Image(systemName: draft.icon)
                            .font(.title2)
                            .frame(width: 52, height: 52)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Icon")
                    TextField("Name", text: $draft.name)
                        .font(.title3.weight(.medium))
                }
            }

            Section {
                Picker("Kind", selection: $draft.kind) {
                    Text("AI formatting").tag(Mode.Kind.aiFormat)
                    Text("Plain dictation").tag(Mode.Kind.plainDictation)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(draft.usesAI
                     ? "The transcript is rewritten by your AI provider using the instructions below."
                     : "The transcript is inserted as spoken. Works offline, no AI.")
            }

            if draft.usesAI {
                Section("Instructions") {
                    TextEditor(text: $draft.instructions)
                        .frame(minHeight: 160)
                        .font(.callout)
                }
            }

            Section {
                Picker("Spoken language", selection: $draft.language) {
                    Text("Detect automatically").tag(String?.none)
                    ForEach(LanguageOptions.tags, id: \.self) { tag in
                        Text(LanguageOptions.name(for: tag)).tag(Optional(tag))
                    }
                }
                Toggle("Output in English", isOn: $draft.translateToEnglish)
            } header: {
                Text("Language")
            } footer: {
                Text("Apple Speech cannot detect the language; it uses this language or your device language. Whisper translates while transcribing when “Output in English” is on.")
            }

            Section {
                Toggle("Use a different AI provider", isOn: Binding(
                    get: { draft.providerOverride != nil },
                    set: { draft.providerOverride = $0 ? model.settings.settings.defaultProvider : nil }
                ))
                .disabled(!draft.usesAI)
                if let override = draft.providerOverride, draft.usesAI {
                    ProviderConfigurationFields(configuration: Binding(
                        get: { override },
                        set: { draft.providerOverride = $0 }
                    ))
                }
            } header: {
                Text("AI provider")
            } footer: {
                Text("Otherwise the default from Settings is used. API keys are shared by all modes.")
            }

            Section {
                Toggle("Use a different engine", isOn: Binding(
                    get: { draft.engineOverride != nil },
                    set: { draft.engineOverride = $0 ? model.settings.settings.defaultEngine : nil }
                ))
                if let override = draft.engineOverride {
                    EngineSelectionFields(selection: Binding(
                        get: { override },
                        set: { draft.engineOverride = $0 }
                    ))
                }
            } header: {
                Text("Transcription")
            }
        }
        .navigationTitle(isNew ? "New Mode" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark", role: .confirm) { save() }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .sheet(isPresented: $showingSymbols) {
            SymbolPicker(selection: $draft.icon)
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            try model.modes.save(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A grid of SF Symbols suited to modes.
struct SymbolPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    static let symbols = [
        "mic", "text.bubble", "sparkles", "message", "envelope", "list.bullet", "text.append",
        "globe", "doc.text", "note.text", "pencil", "pencil.and.scribble", "checklist",
        "lightbulb", "briefcase", "graduationcap", "book", "quote.bubble", "bubble.left.and.bubble.right",
        "person.2", "phone", "calendar", "cart", "heart", "star", "bolt", "brain", "wand.and.stars",
        "chevron.left.forwardslash.chevron.right", "terminal", "number", "character.book.closed",
        "translate", "megaphone", "hand.wave", "face.smiling", "paperplane", "tag", "flag", "house"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button {
                            selection = symbol
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.title2)
                                .frame(width: 56, height: 56)
                                .foregroundStyle(symbol == selection ? Color.white : Color.primary)
                                .background(
                                    symbol == selection ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: .rect(cornerRadius: 14)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding()
            }
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
