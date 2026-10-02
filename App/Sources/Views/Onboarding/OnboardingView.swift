import AVFoundation
import KVoiceKit
import SwiftUI

/// First launch: microphone, engine, optional AI, keyboard.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, microphone, engine, ai, keyboard }
    @State private var step: Step = .welcome
    @State private var micGranted = AudioRecorder.hasPermission

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
                .padding(24)
        }
        .animation(.smooth, value: step)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            OnboardingPage(
                icon: "waveform", title: "Welcome to KVoice",
                text: "Speak once, get finished text in any app. KVoice transcribes on your device and can tidy what you said into a message, an email or notes."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Feature(icon: "lock.shield", text: "Private by default: recordings stay on this device.")
                    Feature(icon: "square.stack.3d.up", text: "Modes for every kind of writing, or plain dictation with no AI.")
                    Feature(icon: "keyboard", text: "A keyboard that brings dictation to every app.")
                }
            }
        case .microphone:
            OnboardingPage(
                icon: "mic.fill", title: "Microphone",
                text: "KVoice listens only while you dictate. The microphone indicator shows whenever it is on."
            ) {
                if micGranted {
                    Label("Microphone access is on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else {
                    Button("Allow Microphone", systemImage: "mic") {
                        Task { micGranted = await AudioRecorder.requestPermission() }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
        case .engine:
            OnboardingPage(
                icon: "text.bubble", title: "Speech recognition",
                text: "Choose how speech becomes text. You can change this any time in Settings, where you can also use cloud transcription with your own OpenAI, Groq, Google AI Studio or Google Vertex AI key."
            ) {
                EngineChoice()
            }
        case .ai:
            OnboardingPage(
                icon: "sparkles", title: "AI formatting (optional)",
                text: "AI modes rewrite your words into clean text. Use Apple Intelligence on this device, or add your own key for OpenAI, Anthropic, Google AI Studio (Gemini), Google Vertex AI, Groq, OpenRouter or any compatible service in Settings."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    AppleIntelligenceStatus()
                    Text("Plain Dictation always works without AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .keyboard:
            OnboardingPage(
                icon: "keyboard", title: "Add the KVoice keyboard",
                text: "Dictate into any app from the KVoice keyboard."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    KeyboardSetupSteps()
                    OpenSettingsButton()
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    .buttonStyle(.glass)
            }
            Spacer()
            Button(step == .keyboard ? "Start Dictating" : "Continue") {
                if let next = Step(rawValue: step.rawValue + 1) { step = next } else { onFinish() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }
}

private struct OnboardingPage<Accessory: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .padding(.top, 24)
            Text(title).font(.largeTitle.bold())
            Text(text).font(.body).foregroundStyle(.secondary)
            accessory.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Feature: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
        }
    }
}

/// Apple Speech or a Whisper model, from onboarding.
private struct EngineChoice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        let assets = model.assets
        VStack(spacing: 12) {
            option(
                title: "Apple Speech", detail: "Built in, fast, no large download.",
                selected: settings.settings.defaultEngine.kind == .appleSpeech
            ) {
                settings.settings.defaultEngine = .appleSpeech
                Task { await assets.installSpeechAssets() }
            }
            option(
                title: "Whisper Base", detail: "On device, 100+ languages, \(WhisperModel.base.approximateSizeMB) MB download.",
                selected: settings.settings.defaultEngine.kind == .whisper
            ) {
                settings.settings.defaultEngine = .whisper(WhisperModel.base.id)
                assets.download(.base)
            }
            if let progress = assets.whisperProgress[WhisperModel.base.id] {
                ProgressView(value: progress) { Text("Downloading Whisper Base…").font(.caption) }
            } else if let progress = assets.speechAssetProgress {
                ProgressView(value: progress) { Text("Downloading speech model…").font(.caption) }
            }
        }
        .task { await assets.refresh() }
    }

    private func option(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.25)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 20))
    }
}
