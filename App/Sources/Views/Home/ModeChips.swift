import KVoiceKit
import SwiftUI

/// The active mode as a row of glass chips.
struct ModeChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(model.modes.modes) { mode in
                            chip(mode)
                                .id(mode.id)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(model.modes.activeModeID, anchor: .center) }
        }
        .disabled(model.pipeline.isBusy)
    }

    private func chip(_ mode: Mode) -> some View {
        let isActive = mode.id == model.modes.activeModeID
        return Button {
            try? model.modes.setActiveMode(id: mode.id)
        } label: {
            Label(mode.name, systemImage: mode.icon)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .glassEffect(isActive ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
