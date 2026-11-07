import SwiftUI
import UIKit

struct KeyboardSetupView: View {
    var body: some View {
        List {
            Section {
                KeyboardSetupSteps()
            } footer: {
                Text("Full Access is needed only for dictation: it lets the keyboard talk to the KVoice app on this device. Typing works without it. KVoice never sees what you type with other keyboards, and the KVoice keyboard sends nothing off the device.")
            }
            Section {
                OpenSettingsButton()
            }
            Section("How it works") {
                Text("Type with KVoice like any keyboard. To dictate, tap the microphone in the bar above the keys: KVoice opens to listen, you swipe back, and the text is typed where you left off. For a few minutes afterwards the microphone works without leaving your app. Tap the globe to switch to another keyboard.")
                    .font(.callout)
            }
        }
        .navigationTitle("Keyboard")
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyboardSetupSteps: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    static let steps: [(String, String)] = [
        ("gearshape", "Open the Settings app"),
        ("switch.2", "Go to General › Keyboard › Keyboards"),
        ("plus.circle", "Tap Add New Keyboard… and choose KVoice"),
        ("lock.open", "For dictation, tap KVoice and turn on Allow Full Access"),
        ("globe", "In any app, hold the globe key to switch to KVoice")
    ]

    var body: some View {
        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
            if typeSize.isAccessibilitySize {
                // A fixed-size number circle cannot hold the large digit.
                Text("\(index + 1). \(step.1)")
            } else {
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
}

struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings", systemImage: "arrow.up.forward.app") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}
