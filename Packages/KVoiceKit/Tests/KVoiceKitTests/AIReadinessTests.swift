import Foundation
import Testing
@testable import KVoiceKit

@MainActor
@Suite struct AIReadinessTests {
    let directory: TempDirectory
    let defaults = TestDefaults()

    init() throws {
        directory = try TempDirectory()
    }

    func makeStore() -> ModeStore {
        ModeStore(directory: directory.url, defaults: defaults.defaults, postsNotifications: false)
    }

    func needsSetup(_ mode: Mode, settings: Settings = Settings(), ai: Bool = false, keys: Set<ProviderKind> = []) -> Bool {
        AIReadiness.needsSetup(mode, settings: settings, appleIntelligenceAvailable: ai) { keys.contains($0) }
    }

    @Test func needsSetupOnlyWhenTheModesProviderCannotRun() {
        #expect(!needsSetup(.dictation))
        #expect(needsSetup(.cleanUp))
        #expect(!needsSetup(.cleanUp, ai: true))
        let cloud = Settings(defaultProvider: ProviderConfiguration(kind: .openAI))
        #expect(needsSetup(.cleanUp, settings: cloud, ai: true))
        #expect(!needsSetup(.cleanUp, settings: cloud, keys: [.openAI]))
        var override = Mode.email
        override.providerOverride = ProviderConfiguration(kind: .groq)
        #expect(!needsSetup(override, keys: [.groq]))
    }

    @Test func fallsBackToDictationUnlessTheUserChose() throws {
        defer { directory.cleanUp(); defaults.cleanUp() }
        let store = makeStore()
        try store.setActiveMode(id: Mode.BuiltInID.cleanUp, chosenByUser: false)
        store.fallBackToPlainMode { _ in false }
        #expect(store.activeModeID == Mode.BuiltInID.cleanUp)
        store.fallBackToPlainMode { $0.usesAI }
        #expect(store.activeModeID == Mode.BuiltInID.dictation)
        #expect(!makeStore().activeModeChosenByUser)

        try store.setActiveMode(id: Mode.BuiltInID.email)
        store.fallBackToPlainMode { $0.usesAI }
        #expect(store.activeModeID == Mode.BuiltInID.email)
        #expect(makeStore().activeModeChosenByUser)
    }

    @Test func actionButtonFromModelIdentifier() {
        #expect(!DeviceModel.hasActionButton("iPhone14,5"))  // iPhone 13
        #expect(!DeviceModel.hasActionButton("iPhone15,4"))  // iPhone 15
        #expect(DeviceModel.hasActionButton("iPhone16,1"))   // iPhone 15 Pro
        #expect(DeviceModel.hasActionButton("iPhone17,5"))   // iPhone 16e
        #expect(!DeviceModel.hasActionButton("iPad16,3"))
        #expect(!DeviceModel.hasActionButton("arm64"))
    }
}
