@preconcurrency import AVFoundation
import KVoiceKit
import Observation
import SwiftUI

/// Plays a history recording.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var progress: Double = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func toggle(url: URL) {
        isPlaying ? pause() : play(url: url)
    }

    func play(url: URL) {
        do {
            if player?.url != url {
                // Leave the session alone while the microphone is in use.
                if !AppModel.shared.recorder.isEngineRunning {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                }
                player = try AVAudioPlayer(contentsOf: url)
            }
            player?.play()
            isPlaying = true
            startTicker()
        } catch {
            isPlaying = false
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
        ticker?.cancel()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying {
                    self.isPlaying = false
                    if self.progress < 0.01 || player.currentTime == 0 { self.progress = 0 }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

struct AudioPlayerBar: View {
    let player: AudioPlayer
    let url: URL
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")

            ProgressView(value: player.progress)
                .tint(.accentColor)

            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .capsule)
    }
}
