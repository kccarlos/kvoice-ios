import AppIntents
import Foundation
import KVoiceCore

/// A KVoice mode as an App Intents entity (Shortcuts, Siri, widgets).
struct ModeEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mode" }
    static var defaultQuery: ModeQuery { ModeQuery() }

    let id: UUID
    let name: String
    let icon: String

    init(id: UUID, name: String, icon: String) {
        self.id = id
        self.name = name
        self.icon = icon
    }

    init(_ mode: Mode) {
        self.init(id: mode.id, name: mode.name, icon: mode.icon)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }
}

/// Reads modes from the App Group, so it works in the app and the widget.
struct ModeQuery: EntityQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ModeEntity] {
        let store = ModeStore(postsNotifications: false)
        return identifiers.compactMap(store.mode(id:)).map(ModeEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ModeEntity] {
        ModeStore(postsNotifications: false).modes.map(ModeEntity.init)
    }
}
