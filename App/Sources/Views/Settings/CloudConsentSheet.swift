import KVoiceKit
import SwiftUI

/// Asked once per cloud provider, before KVoice sends it anything.
struct CloudConsentSheet: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind

    var body: some View {
        let settings = model.settings.settings
        let name = provider.displayName
        let host = provider == .customOpenAICompatible
            ? (settings.configuration(for: provider).baseURL ?? settings.defaultEngine.cloud?.baseURL)?.host()
            : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                Text("Send your dictation to \(name)?")
                    .font(.title2.bold())
                Text("You chose \(name)\(host.map { " (\($0))" } ?? ""). To use it, KVoice sends this from your iPhone directly to \(name) with your API key:")
                if provider.supportsTranscription {
                    Label("The audio of each dictation, when it transcribes", systemImage: "waveform")
                }
                Label("The transcript and the mode's instructions, when it formats with an AI mode", systemImage: "text.quote")
                Text("\(name)'s privacy policy and terms apply to what it receives. KVoice has no servers, and its developer never receives your dictation. You can withdraw this in Settings › Privacy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    model.allowCloud(provider)
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button {
                    model.revokeCloud(provider)
                } label: {
                    Text("Don't Allow, Stay On Device").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(24)
        }
        .interactiveDismissDisabled()
    }
}
