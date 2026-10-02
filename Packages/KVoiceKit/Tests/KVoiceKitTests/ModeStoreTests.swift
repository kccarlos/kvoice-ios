import Foundation
import Testing
@testable import KVoiceKit

@MainActor
@Suite struct ModeStoreTests {
    let directory: TempDirectory
    let defaults = TestDefaults()

    init() throws {
        directory = try TempDirectory()
    }

    func makeStore() -> ModeStore {
        ModeStore(directory: directory.url, defaults: defaults.defaults, postsNotifications: false)
    }

    @Test func startsWithBuiltInsAndDictationActive() {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let store = makeStore()
        #expect(store.modes == Mode.builtIns)
        #expect(store.activeMode == .dictation)
    }

    @Test func createEditDeletePersistAcrossInstances() throws {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let store = makeStore()
        var custom = Mode(
            name: "Tweet", icon: "bird", instructions: "Under 280 characters.",
            language: "en-US",
            providerOverride: ProviderConfiguration(kind: .anthropic),
            engineOverride: .whisper("small")
        )
        try store.save(custom)
        #expect(store.modes.count == Mode.builtIns.count + 1)

        custom.name = "Post"
        try store.save(custom)
        #expect(store.modes.count == Mode.builtIns.count + 1)

        let reloaded = makeStore()
        let saved = try #require(reloaded.mode(id: custom.id))
        #expect(saved == custom)
        #expect(saved.providerOverride?.model == "claude-sonnet-5-5")
        #expect(saved.engineOverride?.whisperModelID == "small")

        try reloaded.delete(id: custom.id)
        #expect(makeStore().mode(id: custom.id) == nil)
    }

    @Test func activeModeIsSharedThroughDefaults() throws {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let app = makeStore()
        try app.setActiveMode(id: Mode.BuiltInID.email)
        let keyboard = makeStore()
        #expect(keyboard.activeMode.id == Mode.BuiltInID.email)

        try app.setActiveMode(id: Mode.BuiltInID.notes)
        keyboard.reload()
        #expect(keyboard.activeMode.id == Mode.BuiltInID.notes)
    }

    @Test func deletingActiveModeFallsBackToFirst() throws {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let store = makeStore()
        try store.setActiveMode(id: Mode.BuiltInID.summary)
        try store.delete(id: Mode.BuiltInID.summary)
        #expect(store.activeModeID == Mode.BuiltInID.dictation)
        #expect(store.mode(id: Mode.BuiltInID.summary) == nil)
    }

    @Test func rejectsUnknownAndNamelessModes() {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let store = makeStore()
        #expect(throws: ModeStore.StoreError.notFound) { try store.setActiveMode(id: UUID()) }
        #expect(throws: ModeStore.StoreError.emptyName) { try store.save(Mode(name: "  ")) }
    }

    @Test func moveAndResetBuiltIns() throws {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let store = makeStore()
        try store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.modes[2] == .dictation)
        #expect(makeStore().modes[2] == .dictation)

        var edited = Mode.cleanUp
        edited.instructions = "Changed"
        try store.save(edited)
        let custom = Mode(name: "Mine")
        try store.save(custom)
        try store.resetBuiltIns()
        #expect(store.modes.prefix(Mode.builtIns.count) == ArraySlice(Mode.builtIns))
        #expect(store.modes.last == custom)
    }

    @Test func corruptFileFallsBackToBuiltIns() throws {
        defer { directory.cleanUp(); defaults.cleanUp() }
        try Data("not json".utf8).write(to: directory.url.appending(path: ModeStore.fileName))
        #expect(makeStore().modes == Mode.builtIns)
    }

    @Test func settingsPersistAndResolvePerMode() {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let store = SettingsStore(defaults: defaults.defaults, postsNotifications: false)
        #expect(store.settings == Settings())
        store.settings.defaultEngine = .whisper("tiny")
        store.settings.defaultProvider = ProviderConfiguration(kind: .gemini)
        store.settings.retention = RetentionPolicy(period: .days7, keepsAudio: false)
        store.settings.providerConfigurations[.groq] = ProviderConfiguration(kind: .groq, model: "custom-model")

        let reloaded = SettingsStore(defaults: defaults.defaults, postsNotifications: false)
        #expect(reloaded.settings == store.settings)
        #expect(reloaded.settings.configuration(for: .groq).model == "custom-model")
        #expect(reloaded.settings.configuration(for: .openAI) == ProviderConfiguration(kind: .openAI))

        var mode = Mode.email
        #expect(reloaded.settings.provider(for: mode).kind == .gemini)
        mode.providerOverride = .appleIntelligence
        mode.engineOverride = .appleSpeech
        #expect(reloaded.settings.provider(for: mode) == .appleIntelligence)
        #expect(reloaded.settings.engine(for: mode) == .appleSpeech)
    }
}
