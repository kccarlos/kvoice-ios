import SwiftUI
import UIKit

struct KeyboardSetupView: View {
    var body: some View {
        List {
            Section {
                KeyboardSetupSteps()
            } footer: {
                Text("Full Access lets the keyboard talk to the KVoice app on this device (to receive your dictation and read your modes). KVoice never sees what you type with other keyboards, and the KVoice keyboard sends nothing off the device.")
            }
            Section {
                OpenSettingsButton()
            }
            Section("How it works") {
                Text("iOS keyboards cannot use the microphone. When you tap the microphone in the KVoice keyboard, KVoice opens, starts listening, and you swipe back to your app. The text is typed where you left off. For a few minutes afterwards the keyboard can start and stop dictation without switching apps.")
                    .font(.callout)
            }
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyboardSetupSteps: View {
    static let steps: [(String, String)] = [
        ("gearshape", "Open the Settings app"),
        ("switch.2", "Go to General › Keyboard › Keyboards"),
        ("plus.circle", "Tap Add New Keyboard… and choose KVoice"),
        ("lock.open", "Tap KVoice and turn on Allow Full Access"),
        ("globe", "In any app, hold the globe key to switch to KVoice")
    ]

    var body: some View {
        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
            HStack(spacing: 14) {
                Text("\(index + 1)")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: .circle)
                Label(step.1, systemImage: step.0)
            }
        }
    }
}

struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings", systemImage: "arrow.up.forward.app") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}
