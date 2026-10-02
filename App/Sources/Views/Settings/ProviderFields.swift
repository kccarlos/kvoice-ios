import KVoiceKit
import SwiftUI

/// Provider, base URL, model and API key for an AI step.
struct ProviderConfigurationFields: View {
    @Environment(AppModel.self) private var model
    @Binding var configuration: ProviderConfiguration

    var body: some View {
        Picker("Provider", selection: Binding(
            get: { configuration.kind },
            set: { configuration = model.settings.settings.configuration(for: $0) }
        )) {
            ForEach(ProviderKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }

        if configuration.kind == .appleIntelligence {
            AppleIntelligenceStatus()
        } else {
            BaseURLField(
                url: $configuration.baseURL,
                placeholder: configuration.kind.defaultBaseURL?.absoluteString ?? "https://example.com/v1",
                isRequired: configuration.kind == .customOpenAICompatible
            )
            .id(configuration.kind)
            LabeledContent("Model") {
                TextField(configuration.kind.defaultModel.isEmpty ? "model-name" : configuration.kind.defaultModel,
                          text: $configuration.model)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            APIKeyField(provider: configuration.kind)
            ProviderSetupHint(provider: configuration.kind)
        }
    }
}

/// Where to get a key and what the base URL means, for providers that need
/// more than a pasted key.
struct ProviderSetupHint: View {
    let provider: ProviderKind

    var body: some View {
        if let text = provider.setupHint {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension ProviderKind {
    var setupHint: String? {
        switch self {
        case .gemini:
            "Create a key at aistudio.google.com (Get API key). Type any Gemini model ID, for example gemini-2.5-flash."
        case .vertexAI:
            "Use a Vertex AI express-mode API key from the Google Cloud console with the default URL, or set the base URL to https://LOCATION-aiplatform.googleapis.com/v1/projects/PROJECT/locations/LOCATION. Type any Gemini model ID, for example gemini-2.5-flash."
        default:
            nil
        }
    }
}

struct AppleIntelligenceStatus: View {
    var body: some View {
        let availability = AppleIntelligenceFormatter.availability
        Label(availability.message, systemImage: availability.isAvailable ? "checkmark.circle.fill" : "info.circle")
            .foregroundStyle(availability.isAvailable ? Color.green : Color.secondary)
            .font(.callout)
    }
}

struct BaseURLField: View {
    @Binding var url: URL?
    let placeholder: String
    let isRequired: Bool
    @State private var text = ""

    var body: some View {
        LabeledContent(isRequired ? "Base URL" : "Base URL (optional)") {
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(commit)
                .onChange(of: text) { commit() }
        }
        .onAppear { text = url?.absoluteString ?? "" }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let newValue = trimmed.isEmpty ? nil : URL(string: trimmed)
        if newValue != url { url = newValue }
    }
}

/// Saves an API key to the Keychain. The stored key is never shown back;
/// only its last four characters.
struct APIKeyField: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    @State private var entry = ""
    @State private var savedHint: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API key")
                Spacer()
                if let savedHint {
                    Label("Saved ••••\(savedHint)", systemImage: "key.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            HStack {
                SecureField(savedHint == nil ? "Paste your \(provider.displayName) key" : "Replace key", text: $entry)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
                if !entry.isEmpty {
                    Button("Save", action: save)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                } else if savedHint != nil {
                    Button("Remove", role: .destructive) { store(nil) }
                        .controlSize(.small)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: provider) { load() }
    }

    private func load() {
        entry = ""
        errorMessage = nil
        guard let key = try? model.secrets.apiKey(for: provider), !key.isEmpty else {
            savedHint = nil
            return
        }
        savedHint = String(key.suffix(4))
    }

    private func save() {
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store(entry)
    }

    private func store(_ key: String?) {
        do {
            try model.secrets.setAPIKey(key, for: provider)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Engine kind plus the Whisper model or cloud endpoint.
struct EngineSelectionFields: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: TranscriptionEngineSelection

    var body: some View {
        Picker("Engine", selection: Binding(
            get: { selection.kind },
            set: { kind in
                switch kind {
                case .appleSpeech: selection = .appleSpeech
                case .whisper: selection = .whisper(selection.whisperModelID ?? WhisperModel.base.id)
                case .cloud: selection = .cloud(selection.cloud ?? CloudTranscriptionConfiguration(provider: .openAI))
                }
            }
        )) {
            ForEach(TranscriptionEngineSelection.Kind.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
            }
        }

        switch selection.kind {
        case .appleSpeech:
            EmptyView()
        case .whisper:
            Picker("Model", selection: Binding(
                get: { selection.whisperModelID ?? WhisperModel.base.id },
                set: { selection.whisperModelID = $0 }
            )) {
                ForEach(WhisperModel.all) { whisper in
                    let installed = model.assets.installedWhisperModels.contains(whisper.id)
                    Text(installed ? whisper.name : "\(whisper.name) (not downloaded)").tag(whisper.id)
                }
            }
        case .cloud:
            CloudTranscriptionFields(configuration: Binding(
                get: { selection.cloud ?? CloudTranscriptionConfiguration(provider: .openAI) },
                set: { selection.cloud = $0 }
            ))
        }
    }
}

struct CloudTranscriptionFields: View {
    @Binding var configuration: CloudTranscriptionConfiguration

    var body: some View {
        Picker("Provider", selection: Binding(
            get: { configuration.provider },
            set: { configuration = CloudTranscriptionConfiguration(provider: $0) }
        )) {
            ForEach(ProviderKind.allCases.filter(\.supportsTranscription)) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        BaseURLField(
            url: $configuration.baseURL,
            placeholder: configuration.provider.defaultBaseURL?.absoluteString ?? "https://example.com/v1",
            isRequired: configuration.provider == .customOpenAICompatible
        )
        .id(configuration.provider)
        LabeledContent("Model") {
            TextField(configuration.provider.defaultTranscriptionModel ?? "whisper-1", text: $configuration.model)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        APIKeyField(provider: configuration.provider)
        ProviderSetupHint(provider: configuration.provider)
    }
}

extension TranscriptionEngineSelection.Kind {
    var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .whisper: "Whisper (on device)"
        case .cloud: "Cloud (your key)"
        }
    }
}
