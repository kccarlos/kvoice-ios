import SwiftUI
import KVoiceKit

@main
struct KVoiceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("KVoice", systemImage: "waveform",
                                   description: Text("Dictation is coming soon."))
        }
    }
}
