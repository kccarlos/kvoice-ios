import SwiftUI

/// The big microphone button: hold to talk (release stops), or tap to start
/// and tap again to stop.
struct RecordButton: View {
    let isRecording: Bool
    /// Transcribing or formatting: the button is disabled.
    let isBusy: Bool
    let level: CGFloat
    let onStart: () -> Void
    let onStop: () -> Void

    /// Presses shorter than this are taps (toggle); longer ones are holds.
    static let holdThreshold: TimeInterval = 0.45

    @State private var pressStartedAt: Date?
    @State private var pressStartedRecording = false

    var body: some View {
        ZStack {
            // Level halo while recording.
            Circle()
                .fill(Color.red.opacity(0.18))
                .frame(width: 168, height: 168)
                .scaleEffect(isRecording ? 1 + level * 0.45 : 0.9)
                .opacity(isRecording ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: level)

            Image(systemName: icon)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(isRecording ? Color.white : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 148, height: 148)
                .glassEffect(
                    isRecording ? .regular.tint(.red).interactive() : .regular.interactive(),
                    in: .circle
                )
                .scaleEffect(pressStartedAt != nil ? 0.94 : 1)
                .animation(.spring(duration: 0.25), value: pressStartedAt != nil)
        }
        .frame(width: 200, height: 200)
        .contentShape(.circle)
        .opacity(isBusy ? 0.5 : 1)
        .gesture(pressGesture, isEnabled: !isBusy)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
        .accessibilityElement()
        .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            isRecording ? onStop() : onStart()
        }
    }

    private var icon: String {
        if isBusy { return "ellipsis" }
        return isRecording ? "stop.fill" : "mic.fill"
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStartedAt == nil else { return }
                pressStartedAt = .now
                pressStartedRecording = !isRecording
                if pressStartedRecording { onStart() }
            }
            .onEnded { _ in
                let held = pressStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0
                defer { pressStartedAt = nil }
                if pressStartedRecording {
                    // A hold ends the dictation on release; a tap keeps recording.
                    if held >= Self.holdThreshold { onStop() }
                } else {
                    onStop()
                }
            }
    }
}

/// Bars that follow the microphone level.
struct WaveformView: View {
    let levels: [CGFloat]
    let isActive: Bool

    static let barCount = 40
    static var silentLevels: [CGFloat] { Array(repeating: 0, count: barCount) }

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let spacing: CGFloat = 3
            let width = max(1, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            for (index, level) in levels.enumerated() {
                // Emphasise speech: the level is already 0...1 on a dB scale.
                let shaped = pow(max(0, min(1, level)), 1.6)
                let height = max(4, shaped * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (width + spacing),
                    y: (size.height - height) / 2,
                    width: width, height: height
                )
                let fade = 0.35 + 0.65 * CGFloat(index) / CGFloat(count)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color((isActive ? Color.red : Color.secondary).opacity(isActive ? fade : 0.3))
                )
            }
        }
        .accessibilityHidden(true)
    }
}
