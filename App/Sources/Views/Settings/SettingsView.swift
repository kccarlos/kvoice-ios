import KVoiceKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppPreferences.autoCopyKey, store: AppPreferences.store) private var autoCopy = true
    @AppStorage(AppPreferences.keepAliveMinutesKey, store: AppPreferences.store) private var keepAliveMinutes = 5
    @State private var confirmingDeleteHistory = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section("Speech and AI") {
                    NavigationLink {
                        TranscriptionSettingsView()
                    } label: {
                        SettingsRow(title: "Transcription", detail: settings.settings.defaultEngine.displayName,
                                    icon: "waveform", color: .blue)
                    }
                    NavigationLink {
                        AIProviderSettingsView()
                    } label: {
                        SettingsRow(title: "AI formatting", detail: settings.settings.defaultProvider.kind.displayName,
                                    icon: "sparkles", color: .purple)
                    }
                }

                Section {
                    Toggle("Copy results automatically", isOn: $autoCopy)
                    Picker("Keep listening for the keyboard", selection: $keepAliveMinutes) {
                        ForEach(AppPreferences.keepAliveChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "Off" : "\(minutes) min").tag(minutes)
                        }
                    }
                    .onChange(of: keepAliveMinutes) { _, minutes in
                        if minutes == 0 { model.handoff.endStandby() }
                    }
                } header: {
                    Text("Dictation")
                } footer: {
                    Text("After a dictation from the KVoice keyboard, KVoice keeps the microphone ready in the background for this long, so the keyboard can start the next dictation without switching apps. The microphone indicator stays on while it waits.")
                }

                Section {
                    Picker("Keep history", selection: $settings.settings.retention.period) {
                        Text("Forever").tag(RetentionPeriod.forever)
                        Text("30 days").tag(RetentionPeriod.days30)
                        Text("7 days").tag(RetentionPeriod.days7)
                    }
                    Toggle("Keep audio recordings", isOn: $settings.settings.retention.keepsAudio)
                    Button("Delete All History", role: .destructive) { confirmingDeleteHistory = true }
                } header: {
                    Text("History")
                } footer: {
                    Text("Without audio, history keeps only text and dictations cannot be transcribed again.")
                }
                .onChange(of: settings.settings.retention) {
                    Task { await model.applyRetention() }
                }

                Section("Keyboard") {
                    NavigationLink {
                        KeyboardSetupView()
                    } label: {
                        SettingsRow(title: "Set up the KVoice keyboard", detail: nil, icon: "keyboard", color: .gray)
                    }
                }

                Section("Privacy") {
                    Label {
                        Text("Recordings and transcripts stay on this device. Nothing is sent anywhere unless you choose a cloud engine or AI provider, and then only the text or audio of that dictation goes to it with your key. No analytics, no accounts.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(.green)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("License", value: "MIT")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all history?", isPresented: $confirmingDeleteHistory, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    Task {
                        try? await model.history?.deleteAll()
                        model.historyChanged()
                    }
                }
            } message: {
                Text("All transcripts and recordings are removed from this device.")
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

struct SettingsRow: View {
    let title: String
    let detail: String?
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: .rect(cornerRadius: 8))
            Text(title)
            Spacer()
            if let detail {
                Text(detail).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct AIProviderSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ProviderConfigurationFields(configuration: Binding(
                    get: { settings.settings.defaultProvider },
                    set: { configuration in
                        settings.settings.defaultProvider = configuration
                        settings.settings.providerConfigurations[configuration.kind] = configuration
                    }
                ))
            } header: {
                Text("Default provider")
            } footer: {
                Text("Used by AI modes unless a mode picks its own. Apple Intelligence runs on this device with no key. Other providers use your own API key, stored in the Keychain on this device.")
            }

            Section {
                Text("Plain Dictation mode never uses AI and works offline. If an AI step fails, KVoice keeps the transcript so nothing you said is lost.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI formatting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TranscriptionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let assets = model.assets
        let engine = settings.settings.defaultEngine
        Form {
            Section {
                ForEach(TranscriptionEngineSelection.Kind.allCases, id: \.self) { kind in
                    Button {
                        select(kind)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName).foregroundStyle(.primary)
                                Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if engine.kind == kind {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
                            }
                        }
                    }
                }
            } header: {
                Text("Default engine")
            } footer: {
                Text("Modes can choose their own engine.")
            }

            Section {
                if !AppleSpeechEngine.isAvailable {
                    Label("On-device speech recognition is not available on this device.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Language", value: Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier)
                    if let progress = assets.speechAssetProgress {
                        ProgressView(value: progress) { Text("Downloading speech model…") }
                    } else {
                        switch assets.speechAssetStatus {
                        case .installed:
                            Label("Speech model installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .unsupported:
                            Label("Your device language is not supported. Pick a language in a mode.", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        case .downloading:
                            Label("The speech model is downloading.", systemImage: "arrow.down.circle")
                        case .supported, nil:
                            Button("Download Speech Model", systemImage: "arrow.down.circle") {
                                Task { await assets.installSpeechAssets() }
                            }
                        }
                    }
                }
            } header: {
                Text("Apple Speech")
            } footer: {
                Text("Apple's on-device recognizer. It downloads a small model per language the first time.")
            }

            Section {
                ForEach(WhisperModel.all) { whisper in
                    WhisperModelRow(
                        whisper: whisper,
                        isSelected: engine.kind == .whisper && (engine.whisperModelID ?? WhisperModel.base.id) == whisper.id,
                        onSelect: { settings.settings.defaultEngine = .whisper(whisper.id) }
                    )
                }
            } header: {
                Text("Whisper models")
            } footer: {
                Text("Whisper runs on this device in 100+ languages, detects the language, and can translate to English. Models download once from the WhisperKit model repository.")
            }

            if engine.kind == .cloud {
                Section {
                    CloudTranscriptionFields(configuration: Binding(
                        get: { settings.settings.defaultEngine.cloud ?? CloudTranscriptionConfiguration(provider: .openAI) },
                        set: { settings.settings.defaultEngine = .cloud($0) }
                    ))
                } header: {
                    Text("Cloud transcription")
                } footer: {
                    Text("Audio is sent to the provider you choose (any OpenAI-compatible /audio/transcriptions endpoint) with your key.")
                }
            }
        }
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await assets.refresh() }
        .alert("Download failed", isPresented: Binding(
            get: { assets.errorMessage != nil }, set: { if !$0 { assets.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(assets.errorMessage ?? "")
        }
    }

    private func select(_ kind: TranscriptionEngineSelection.Kind) {
        let settings = model.settings
        switch kind {
        case .appleSpeech:
            settings.settings.defaultEngine = .appleSpeech
        case .whisper:
            let installed = WhisperModel.all.first { model.assets.installedWhisperModels.contains($0.id) }
            settings.settings.defaultEngine = .whisper((installed ?? .base).id)
        case .cloud:
            settings.settings.defaultEngine = .cloud(
                settings.settings.defaultEngine.cloud ?? CloudTranscriptionConfiguration(provider: .openAI)
            )
        }
    }
}

struct WhisperModelRow: View {
    @Environment(AppModel.self) private var model
    let whisper: WhisperModel
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        let assets = model.assets
        let installed = assets.installedWhisperModels.contains(whisper.id)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(whisper.name).font(.body.weight(.medium))
                    Text("\(whisper.approximateSizeMB) MB").font(.caption).foregroundStyle(.secondary)
                }
                Text(whisper.summary).font(.caption).foregroundStyle(.secondary)
                if let progress = assets.whisperProgress[whisper.id] {
                    ProgressView(value: progress)
                        .padding(.top, 4)
                }
            }
            Spacer()
            if assets.isDownloading(whisper) {
                Button("Cancel", systemImage: "xmark.circle") { assets.cancelDownload(whisper) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            } else if installed {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
                } else {
                    Button("Use", action: onSelect).buttonStyle(.glass).controlSize(.small)
                }
            } else {
                Button("Get", systemImage: "arrow.down.circle") { assets.download(whisper) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .swipeActions {
            if installed {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .contextMenu {
            if installed {
                Button("Delete Model", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .confirmationDialog("Delete the \(whisper.name) model?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await assets.delete(whisper) } }
        }
    }
}

extension TranscriptionEngineSelection.Kind {
    var summary: String {
        switch self {
        case .appleSpeech: "On device, no download beyond a small system model."
        case .whisper: "On device, downloadable models, 100+ languages."
        case .cloud: "OpenAI, Groq or a custom endpoint with your API key."
        }
    }
}
