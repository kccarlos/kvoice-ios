import AppIntents
import KVoiceCore
import SwiftUI
import WidgetKit

@main
struct KVoiceWidgetBundle: WidgetBundle {
    var body: some Widget {
        DictateControl()
        DictateWidget()
    }
}

// MARK: - Control Center

/// A Control Center / Lock Screen / Action Button control that opens KVoice
/// and starts dictating.
struct DictateControl: ControlWidget {
    static let kind = "io.github.kccarlos.kvoice.ios.widgets.dictate-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: DictateIntent()) {
                Label("Dictate", systemImage: "mic.fill")
            }
        }
        .displayName("Dictate with KVoice")
        .description("Open KVoice and start recording.")
    }
}

// MARK: - Home and Lock Screen widget

struct DictateWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Dictation Mode" }
    static var description: IntentDescription { IntentDescription("The mode the widget dictates in.") }

    @Parameter(title: "Mode", description: "Leave empty to use the active mode.")
    var mode: ModeEntity?

    init() {}
}

struct DictateEntry: TimelineEntry {
    let date: Date
    let modeName: String
    let icon: String
    /// Nil: use whatever mode is active when tapped.
    let modeID: UUID?
}

struct DictateProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DictateEntry {
        DictateEntry(date: .now, modeName: "Dictation", icon: "mic", modeID: nil)
    }

    func snapshot(for configuration: DictateWidgetConfiguration, in context: Context) async -> DictateEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: DictateWidgetConfiguration, in context: Context) async -> Timeline<DictateEntry> {
        Timeline(entries: [await entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: DictateWidgetConfiguration) async -> DictateEntry {
        if let mode = configuration.mode {
            return DictateEntry(date: .now, modeName: mode.name, icon: mode.icon, modeID: mode.id)
        }
        let active = await MainActor.run { ModeStore(postsNotifications: false).activeMode }
        return DictateEntry(date: .now, modeName: active.name, icon: active.icon, modeID: nil)
    }
}

struct DictateWidget: Widget {
    static let kind = "io.github.kccarlos.kvoice.ios.widgets.dictate"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: DictateWidgetConfiguration.self, provider: DictateProvider()) { entry in
            DictateWidgetView(entry: entry)
        }
        .configurationDisplayName("Dictate")
        .description("Start a KVoice dictation with one tap.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct DictateWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DictateEntry

    var body: some View {
        content
            .widgetURL(DictationHandoff.appDictationURL(modeID: entry.modeID))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title2.weight(.semibold))
            }
            .containerBackground(for: .widget) {}
            .accessibilityLabel("Dictate with KVoice")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.title3.weight(.semibold))
                VStack(alignment: .leading) {
                    Text("Dictate").font(.headline)
                    Text(entry.modeName).font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {}
        default:
            VStack(alignment: .leading) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.22), in: .circle)
                Spacer()
                Text("Dictate")
                    .font(.headline)
                    .foregroundStyle(.white)
                Label(entry.modeName, systemImage: entry.icon)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
