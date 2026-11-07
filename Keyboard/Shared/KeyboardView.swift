import KVoiceCore
import SwiftUI
import UIKit

/// The KVoice keyboard: a toolbar (mode chips or dictation status, and the
/// mic) over an English QWERTY key area.
struct KeyboardView: View {
    /// About the system keyboard's height, toolbar included.
    static let height: CGFloat = 260
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            KeyboardToolbar(model: model)
                .frame(height: 44)
            KeyboardKeyArea(model: model)
                .overlay(alignment: .top) {
                    if model.showsFullAccessCard {
                        KeyboardFullAccessCard { model.showsFullAccessCard = false }
                    }
                }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toolbar

private struct KeyboardToolbar: View {
    let model: KeyboardModel

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let status {
                    KeyboardStatus(status: status, dismiss: model.dismissFailure)
                } else if model.showsActionButtonTip {
                    tip
                } else if model.hasFullAccess {
                    KeyboardModeBar(model: model)
                } else {
                    Text("Allow Full Access to dictate")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.phase.isActive {
                roundButton("xmark", "Cancel", action: model.cancelTapped)
            } else if model.canUndo {
                roundButton("arrow.uturn.backward", "Undo", action: model.undoTapped)
            } else if model.dictation.showsEndSession {
                roundButton("power", "End KVoice session", action: model.endSessionTapped)
            }
            KeyboardMicButton(phase: model.phase, external: model.dictation.external, action: model.micTapped)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
    }

    private var status: KeyboardStatus.Content? {
        if !model.phase.isActive {
            switch model.dictation.external {
            case .blocked(let message): return .init(text: message, kind: .busy)
            case .appRecording: return .init(text: "Listening in KVoice", kind: .live(since: nil))
            case .none: break
            }
        }
        switch model.phase {
        case .waitingForApp(_, .openedApp, _): return .init(text: "Opening KVoice…", kind: .busy)
        case .waitingForApp(_, .command, _): return .init(text: "Starting…", kind: .busy)
        case .recording: return .init(text: "Listening…", kind: .live(since: model.recordingSince))
        case .stopping, .transcribing: return .init(text: "Transcribing…", kind: .busy)
        case .formatting: return .init(text: "Formatting…", kind: .busy)
        case .failed: return model.failureMessage.map { .init(text: $0, kind: .error) }
        case .idle, .inserted, .cancelled: return nil
        }
    }

    private var tip: some View {
        HStack(spacing: 0) {
            Text("Tip: the Action Button dictates without leaving this app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Button(action: model.dismissTip) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.leading, 6)
    }

    private func roundButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
                .background(KeyboardColors.functionKey, in: .circle)
        }
        .buttonStyle(KeyboardPressStyle())
        .accessibilityLabel(label)
    }
}

/// One line in place of the chips while a dictation runs, or its error.
private struct KeyboardStatus: View {
    struct Content: Equatable {
        enum Kind: Equatable { case live(since: Date?), busy, error }
        let text: String
        let kind: Kind
    }

    let status: Content
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch status.kind {
            case .live: Circle().fill(.red).frame(width: 8, height: 8)
            case .error: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .busy: EmptyView()
            }
            if case .live(let since?) = status.kind {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, context.date.timeIntervalSince(since))
                    Text("\(status.text) \(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))")
                        .monospacedDigit()
                }
            } else {
                Text(status.text)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, 6)
        .contentShape(.rect)
        .onTapGesture { if status.kind == .error { dismiss() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

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
                .padding(.leading, 4)
                .padding(.trailing, 24)
            }
            .scrollIndicators(.hidden)
            .onAppear { if let id = model.activeModeID { proxy.scrollTo(id, anchor: .leading) } }
        }
        // Fade out at the trailing edge instead of a hard clip.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }

    private func chip(_ mode: Mode) -> some View {
        let isActive = mode.id == model.activeModeID
        return Button {
            model.selectMode(mode.id)
        } label: {
            Label(mode.name, systemImage: mode.icon)
                .font(.footnote.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(isActive ? Color.accentColor : KeyboardColors.functionKey, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.name) mode")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct KeyboardMicButton: View {
    let phase: KeyboardDictation.Phase
    let external: KeyboardDictation.External
    let action: () -> Void

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

    private var isProcessing: Bool {
        switch phase {
        case .stopping, .transcribing, .formatting: true
        default: false
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                if isBusy {
                    ProgressView().tint(.white).controlSize(.small)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(KeyboardPressStyle())
        .disabled(isProcessing || isBlocked)
        .accessibilityLabel(isRecording ? "Finish dictation" : "Dictate")
    }

    private var fill: Color {
        if isRecording { return .red }
        if isProcessing || isBlocked { return Color(uiColor: .systemGray) }
        return .accentColor
    }
}

// MARK: - Full Access

/// Shown when the mic is tapped without Full Access; typing still works.
private struct KeyboardFullAccessCard: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Allow Full Access to dictate", systemImage: "lock.open")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button("Close", action: close).font(.subheadline.weight(.semibold))
            }
            step(1, "Open Settings › General › Keyboard › Keyboards")
            step(2, "Tap KVoice, turn on Allow Full Access")
            step(3, "Come back and tap the mic")
            Text("Typing works without it. What you type is never stored or sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
        .font(.footnote)
    }
}

// MARK: - Keys

private struct KeyboardKeyArea: View {
    let model: KeyboardModel

    var body: some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width - 6) / 10
            let rows = KeyboardKeys.rows(model.keys.layer, showsGlobe: model.showsGlobeKey)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    row(rows[index], unit: unit)
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 2)
        }
    }

    private func row(_ keys: [KeyboardKeys.Key], unit: CGFloat) -> some View {
        let characters = keys.filter { if case .character = $0 { true } else { false } }.count
        // Full rows and the letters' shift row use letter-sized keys; the
        // five punctuation keys of the 123 and #+= rows share the width.
        let characterWidth: CGFloat? = characters >= 7 ? unit : nil
        let spaced = characters == 7
        return HStack(spacing: 0) {
            ForEach(keys.indices, id: \.self) { index in
                let key = keys[index]
                if spaced, key == .delete { Spacer(minLength: 0) }
                self.key(key, unit: unit, characterWidth: characterWidth)
                if spaced, key == .shift { Spacer(minLength: 0) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func key(_ key: KeyboardKeys.Key, unit: CGFloat, characterWidth: CGFloat?) -> some View {
        switch key {
        case .character(let character):
            let text = model.keys.text(for: character)
            KeyboardKey(action: { model.tap(key) }) {
                Text(text).font(.system(size: 23))
            }
            .frame(width: characterWidth)
            .frame(maxWidth: characterWidth == nil ? .infinity : nil)
            .accessibilityLabel(text)
            .accessibilityIdentifier("key-\(character)")
        case .shift:
            let shift = model.keys.shift
            KeyboardKey(isFunction: shift == .off, action: { model.tap(.shift) }) {
                Image(systemName: shift == .locked ? "capslock.fill" : shift == .once ? "shift.fill" : "shift")
                    .font(.system(size: 18, weight: .medium))
            }
            .frame(width: unit * 1.3)
            .accessibilityLabel("Shift")
            .accessibilityValue(shift == .locked ? "Caps lock" : shift == .once ? "On" : "Off")
        case .delete:
            KeyboardRepeatingKey(action: { model.tap(.delete) }) {
                Image(systemName: "delete.left").font(.system(size: 18))
            }
            .frame(width: unit * 1.3)
            .accessibilityLabel("Delete")
        case .layer(let layer):
            KeyboardKey(isFunction: true, action: { model.tap(key) }) {
                Text(layer == .letters ? "ABC" : layer == .numbers ? "123" : "#+=").font(.system(size: 16))
            }
            .frame(width: unit * 1.3)
            .accessibilityLabel(layer == .letters ? "Letters" : layer == .numbers ? "Numbers" : "More symbols")
        case .globe:
            KeyboardGlobeKey(model: model)
                .frame(width: unit * 1.3)
        case .space:
            KeyboardSpaceKey(model: model)
        case .returnKey:
            let label = KeyboardKeys.returnKeyLabel(rawValue: model.returnKeyType.rawValue)
            KeyboardKey(isFunction: true, action: { model.tap(.returnKey) }) {
                Text(label).font(.system(size: 16))
            }
            .frame(width: unit * 2.4)
            .accessibilityLabel(label)
        }
    }
}

private struct KeyboardKey<Label: View>: View {
    var isFunction = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(KeyboardKeyStyle(isFunction: isFunction))
            .accessibilityAddTraits(.isKeyboardKey)
    }
}

/// A pressed key swaps to the other key colour, like the system keyboard.
private struct KeyboardKeyStyle: ButtonStyle {
    let isFunction: Bool

    func makeBody(configuration: Configuration) -> some View {
        let function = isFunction != configuration.isPressed
        KeyboardKeyFace(background: function ? KeyboardColors.functionKey : KeyboardColors.letterKey) {
            configuration.label
        }
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
            // The gaps between keys still hit the nearest key.
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
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
            .accessibilityAddTraits([.isButton, .isKeyboardKey])
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

/// Space: a tap types a space; hold, then drag to move the cursor.
private struct KeyboardSpaceKey: View {
    let model: KeyboardModel
    @State private var touchDown: Date?
    /// Set once the hold turned into cursor movement.
    @State private var anchorX: CGFloat?

    private static let pointsPerCharacter: CGFloat = 10

    var body: some View {
        KeyboardKeyFace(background: touchDown != nil && anchorX == nil ? KeyboardColors.functionKey : KeyboardColors.letterKey) {
            Text(anchorX == nil ? "space" : "").font(.system(size: 16))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if touchDown == nil { touchDown = .now }
                    if let anchorX {
                        let steps = Int((value.location.x - anchorX) / Self.pointsPerCharacter)
                        guard steps != 0 else { return }
                        model.moveCursor(by: steps)
                        self.anchorX = anchorX + CGFloat(steps) * Self.pointsPerCharacter
                    } else if let touchDown, Date.now.timeIntervalSince(touchDown) > 0.4 {
                        anchorX = value.location.x
                    }
                }
                .onEnded { _ in
                    if anchorX == nil { model.tap(.space) }
                    touchDown = nil
                    anchorX = nil
                }
        )
        .accessibilityLabel("Space")
        .accessibilityAddTraits([.isButton, .isKeyboardKey])
        .accessibilityAction { model.tap(.space) }
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
