import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

@Suite struct HistoryStoreTests {
    func record(
        raw: String, formatted: String, date: Date = .now, audio: String? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            date: date, duration: 3, modeID: Mode.BuiltInID.cleanUp, modeName: "Clean up",
            engine: "Apple Speech", provider: "Apple Intelligence",
            rawTranscript: raw, formattedText: formatted, audioFileName: audio
        )
    }

    @Test func addFetchUpdateDeletePersist() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let store = try HistoryStore(directory: directory.url)
        let older = record(raw: "first", formatted: "First.", date: .now.addingTimeInterval(-60))
        let newer = record(raw: "second", formatted: "Second.")
        try await store.add(older)
        try await store.add(newer)
        #expect(try await store.all().map(\.id) == [newer.id, older.id])

        var edited = older
        edited.formattedText = "Edited."
        edited.modeName = "Email"
        try await store.update(edited)
        #expect(try await store.record(id: older.id) == edited)

        let reopened = try HistoryStore(directory: directory.url)
        #expect(try await reopened.all().count == 2)

        try await reopened.delete(id: newer.id)
        #expect(try await reopened.all().map(\.id) == [older.id])
        try await reopened.deleteAll()
        #expect(try await reopened.all().isEmpty)
    }

    @Test func searchIsCaseAndDiacriticInsensitiveOverRawAndFormatted() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let store = try HistoryStore(directory: directory.url)
        let cafe = record(raw: "meet at the Café at noon", formatted: "Meet at the café at noon.")
        let resume = record(raw: "send my resume", formatted: "Please find my Résumé attached.")
        let other = record(raw: "buy milk", formatted: "Buy milk.")
        for item in [cafe, resume, other] { try await store.add(item) }

        #expect(try await store.search("CAFE").map(\.id) == [cafe.id])
        #expect(try await store.search("résumé").map(\.id) == [resume.id])
        #expect(try await store.search("RESUME").map(\.id) == [resume.id])
        #expect(try await store.search("attached").map(\.id) == [resume.id], "formatted text is searched")
        #expect(try await store.search("noon").map(\.id) == [cafe.id])
        #expect(try await store.search("nothing here").isEmpty)
        #expect(try await store.search("  ").count == 3)
    }

    @Test func retentionDeletesOldRecordsAndTheirAudio() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let store = try HistoryStore(directory: directory.url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 3600

        let oldAudio = store.newRecordingURL()
        try Data([1]).write(to: oldAudio)
        let old = record(raw: "old", formatted: "Old.", date: now.addingTimeInterval(-40 * day), audio: oldAudio.lastPathComponent)
        let week = record(raw: "week", formatted: "Week.", date: now.addingTimeInterval(-10 * day))
        let fresh = record(raw: "fresh", formatted: "Fresh.", date: now.addingTimeInterval(-1 * day))
        for item in [old, week, fresh] { try await store.add(item) }
        #expect(store.audioURL(for: old) != nil)

        #expect(try await store.applyRetention(RetentionPolicy(period: .forever), now: now) == 0)
        #expect(try await store.all().count == 3)

        #expect(try await store.applyRetention(RetentionPolicy(period: .days30), now: now) == 1)
        #expect(try await store.all().map(\.id) == [fresh.id, week.id])
        #expect(!FileManager.default.fileExists(atPath: oldAudio.path))

        #expect(try await store.applyRetention(RetentionPolicy(period: .days7), now: now) == 1)
        #expect(try await store.all().map(\.id) == [fresh.id])
    }

    @Test func notKeepingAudioRemovesRecordingsButKeepsText() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let store = try HistoryStore(directory: directory.url)
        let audio = store.newRecordingURL()
        try Data([1, 2]).write(to: audio)
        let item = record(raw: "keep me", formatted: "Keep me.", audio: audio.lastPathComponent)
        try await store.add(item)

        try await store.applyRetention(RetentionPolicy(period: .forever, keepsAudio: false))
        let stored = try #require(try await store.record(id: item.id))
        #expect(stored.audioFileName == nil)
        #expect(stored.rawTranscript == "keep me")
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }
}
