import KVoiceCore
import SwiftUI
import UIKit

/// The KVoice keyboard: mode chips, a large mic button with its status,
/// and a row of basic editing keys.
struct KeyboardView: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            if model.hasFullAccess {
                KeyboardModeBar(model: model)
                    .padding(.top, 8)
                Spacer(minLength: 4)
                KeyboardDictationPanel(model: model)
                Spacer(minLength: 4)
            } else {
                KeyboardFullAccessExplainer()
                    .padding(.top, 10)
                Spacer(minLength: 6)
            }
            KeyboardBottomRow(model: model)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Modes

private struct KeyboardModeBar: View {
    let model: KeyboardModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.modes) { mode in
                        chip(mode).id(mode.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            .onAppear { if let id = model.activeModeID { proxy.scrollTo(id, anchor: .center) } }
        }
        .frame(height: 34)
        .disabled(model.phase.isActive)
        .opacity(model.phase.isActive ? 0.5 : 1)
    }

    private func chip(_ mode: Mode) -> some View {
        let isActive = mode.id == model.activeModeID
        return Button {
            model.selectMode(mode.id)
        } label: {
            Label(mode.name, systemImage: mode.icon)
                .font(.footnote.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(isActive ? Color.accentColor : KeyboardColors.functionKey, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.name) mode")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Dictation

private struct KeyboardDictationPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                sideSlot {
                    if model.phase.isActive {
                        KeyboardPillButton(title: "Cancel", systemImage: "xmark", action: model.cancelTapped)
                    }
                }
                Spacer(minLength: 8)
                KeyboardMicButton(phase: model.phase, external: model.dictation.external, action: model.micTapped)
                Spacer(minLength: 8)
                sideSlot {
                    if model.canUndo && !model.phase.isActive {
                        KeyboardPillButton(title: "Undo", systemImage: "arrow.uturn.backward", action: model.undoTapped)
                    }
                }
            }
            .padding(.horizontal, 12)
            KeyboardStatusLine(phase: model.phase, external: model.dictation.external, modeName: model.activeMode?.name)
        }
    }

    private func sideSlot(@ViewBuilder _ content: () -> some View) -> some View {
        // A fixed-width slot even when empty, so the mic stays centred.
        ZStack { Color.clear; content() }
            .frame(width: 104, height: 36)
    }
}

private struct KeyboardMicButton: View {
    let phase: KeyboardDictation.Phase
    let external: KeyboardDictation.External
    let action: () -> Void
    @State private var pulse = false

    private var isRecording: Bool {
        if case .recording = phase { return true }
        // The app records a dictation started elsewhere: the mic stops it.
        if !phase.isActive, case .appRecording = external { return true }
        return false
    }

    /// Another owner holds the microphone, or a job runs.
    private var isBlocked: Bool {
        if !phase.isActive, case .blocked = external { return true }
        return false
    }

    private var isBusy: Bool {
        switch phase {
        case .waitingForApp, .stopping, .transcribing, .formatting: true
        default: false
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 6)
                        .scaleEffect(pulse ? 1.18 : 1)
                        .opacity(pulse ? 0 : 1)
                }
                Circle()
                    .fill(fill)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                if isBusy {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: isRecording ? 28 : 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 78, height: 78)
            .contentShape(Circle())
        }
        .buttonStyle(KeyboardPressStyle())
        .disabled(isProcessing || isBlocked)
        .accessibilityLabel(isRecording ? "Finish dictation" : "Dictate")
        .onChange(of: isRecording, initial: true) { _, recording in
            pulse = false
            guard recording else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var isProcessing: Bool {
        switch phase {
        case .stopping, .transcribing, .formatting: true
        default: false
        }
    }

    private var fill: Color {
        if isRecording { return .red }
        if isProcessing || isBlocked { return Color(uiColor: .systemGray) }
        return .accentColor
    }
}

private struct KeyboardStatusLine: View {
    let phase: KeyboardDictation.Phase
    let external: KeyboardDictation.External
    let modeName: String?

    var body: some View {
        Text(text)
            .font(.subheadline.weight(isError ? .medium : .regular))
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 20)
            .animation(.default, value: text)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var isError: Bool {
        if !phase.isActive, external != .none { return false }
        if case .failed = phase { return true }
        return false
    }

    private var text: String {
        if !phase.isActive {
            switch external {
            case .blocked(let message): return message
            case .appRecording: return "Recording in KVoice… tap to finish"
            case .none: break
            }
        }
        return switch phase {
        case .idle:
            if let modeName { "Ready · \(modeName)" } else { "Ready" }
        case .waitingForApp(_, .openedApp, _): "Opening KVoice…"
        case .waitingForApp(_, .command, _): "Starting…"
        case .recording: "Recording… tap to finish"
        case .stopping, .transcribing: "Transcribing…"
        case .formatting: "Formatting…"
        case .inserted: "Inserted"
        case .failed(let message): message
        case .cancelled: "Cancelled"
        }
    }
}

private struct KeyboardPillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .foregroundStyle(Color.primary)
                .background(KeyboardColors.functionKey, in: .capsule)
        }
        .buttonStyle(KeyboardPressStyle())
    }
}

// MARK: - Full Access

private struct KeyboardFullAccessExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Allow Full Access to dictate", systemImage: "lock.open")
                .font(.headline)
            Text("KVoice records in the app and types the text here. The keyboard needs Full Access to share it with the app. What you type is never stored or sent.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                step(1, "Open Settings › General › Keyboard › Keyboards")
                step(2, "Tap KVoice and turn on Allow Full Access")
                step(3, "Come back here and tap the mic")
            }
            .font(.footnote)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }
}

// MARK: - Keys

private struct KeyboardBottomRow: View {
    let model: KeyboardModel

    var body: some View {
        HStack(spacing: 6) {
            if model.showsGlobeKey {
                KeyboardGlobeKey(model: model)
                    .frame(width: 46)
            }
            KeyboardKey(background: KeyboardColors.letterKey, action: model.insertSpace) {
                Text("space").font(.callout)
            }
            .accessibilityLabel("Space")
            KeyboardRepeatingKey(action: model.deleteBackward) {
                Image(systemName: "delete.left").font(.system(size: 18))
            }
            .frame(width: 58)
            .accessibilityLabel("Delete")
            KeyboardKey(background: KeyboardColors.functionKey, action: model.insertReturn) {
                returnLabel
            }
            .frame(width: 88)
            .accessibilityLabel("Return")
        }
        .frame(height: 44)
    }

    @ViewBuilder private var returnLabel: some View {
        switch model.returnKeyType {
        case .go: Text("go").font(.callout)
        case .search, .google, .yahoo: Text("search").font(.callout)
        case .send: Text("send").font(.callout)
        case .done: Text("done").font(.callout)
        case .next: Text("next").font(.callout)
        case .join: Text("join").font(.callout)
        case .continue: Text("continue").font(.callout)
        case .route: Text("route").font(.callout)
        default: Image(systemName: "return").font(.system(size: 18))
        }
    }
}

private struct KeyboardKey<Label: View>: View {
    let background: Color
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            KeyboardKeyFace(background: background, content: label)
        }
        .buttonStyle(KeyboardPressStyle())
    }
}

private struct KeyboardKeyFace<Content: View>: View {
    let background: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background, in: .rect(cornerRadius: 8))
            .shadow(color: KeyboardColors.keyShadow, radius: 0, y: 1)
            .contentShape(.rect)
    }
}

/// Delete: once on touch-down, then repeating while held.
private struct KeyboardRepeatingKey<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        KeyboardKeyFace(background: repeater == nil ? KeyboardColors.functionKey : KeyboardColors.letterKey, content: label)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in begin() }
                    .onEnded { _ in end() }
            )
            .onDisappear(perform: end)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func begin() {
        guard repeater == nil else { return }
        action()
        repeater = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private func end() {
        repeater?.cancel()
        repeater = nil
    }
}

/// The globe key is a UIButton so the controller can attach
/// `handleInputModeList(from:with:)` (tap: next keyboard; long press: list).
private struct KeyboardGlobeKey: View {
    let model: KeyboardModel

    var body: some View {
        KeyboardKeyFace(background: KeyboardColors.functionKey) {
            Image(systemName: "globe").font(.system(size: 18))
        }
        .overlay { KeyboardInputModeButton(model: model) }
        .accessibilityLabel("Next keyboard")
    }
}

private struct KeyboardInputModeButton: UIViewRepresentable {
    let model: KeyboardModel

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        model.attachInputModeSwitch(to: button)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

private struct KeyboardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

enum KeyboardColors {
    static let letterKey = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
    })
    static let functionKey = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.27, alpha: 1)
            : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
    })
    static let keyShadow = Color(uiColor: UIColor { traits in
        UIColor(white: 0, alpha: traits.userInterfaceStyle == .dark ? 0.5 : 0.3)
    })
    /// The system keyboard backdrop, for hosts that don't provide one.
    static let backdrop = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.17, alpha: 1)
            : UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1)
    })
}
