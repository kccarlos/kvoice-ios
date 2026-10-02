import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

@Suite struct HandoffTests {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requestRoundTripsAndResetsResult() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let keyboard = DictationHandoff(directory: directory.url, postsNotifications: false)
        let app = DictationHandoff(directory: directory.url, postsNotifications: false)

        let request = HandoffRequest(createdAt: fixedDate, modeID: Mode.BuiltInID.email)
        try keyboard.writeRequest(request)
        #expect(app.readRequest() == request)
        #expect(keyboard.readResult() == HandoffResult(
            sessionID: request.sessionID, status: .recording, updatedAt: try #require(keyboard.readResult()?.updatedAt)
        ))

        try app.writeResult(HandoffResult(
            sessionID: request.sessionID, status: .done, text: "Hi team,", updatedAt: fixedDate
        ))
        let result = try #require(keyboard.readResult())
        #expect(result.status == .done && result.status.isFinal)
        #expect(result.text == "Hi team,")
        #expect(!result.consumed)

        try keyboard.markResultConsumed(sessionID: request.sessionID)
        #expect(app.readResult()?.consumed == true)

        app.clearRequest()
        #expect(app.readRequest() == nil)
    }

    @Test func commandsAndAppStateRoundTrip() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let handoff = DictationHandoff(directory: directory.url, postsNotifications: false)
        let command = HandoffCommand(action: .stop, sessionID: UUID(), modeID: Mode.BuiltInID.notes, createdAt: fixedDate)
        try handoff.writeCommand(command)
        #expect(handoff.readCommand() == command)

        let state = HandoffAppState(isListeningForCommands: true, updatedAt: fixedDate)
        try handoff.writeAppState(state)
        #expect(handoff.readAppState() == state)
    }

    @Test func wireFormatIsStable() throws {
        let sessionID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let result = HandoffResult(sessionID: sessionID, status: .failed, errorMessage: "No speech", updatedAt: fixedDate)
        let json = String(decoding: try DictationHandoff.encoder().encode(result), as: UTF8.self)
        #expect(json == #"{"consumed":false,"errorMessage":"No speech","sessionID":"00000000-0000-4000-8000-000000000001","status":"failed","updatedAt":"2027-01-15T08:00:00Z"}"#)
        let decoded = try DictationHandoff.decoder().decode(HandoffResult.self, from: Data(json.utf8))
        #expect(decoded == result)
    }

    @Test func expiry() {
        let request = HandoffRequest(createdAt: fixedDate, modeID: UUID())
        #expect(!request.isExpired(now: fixedDate.addingTimeInterval(60)))
        #expect(request.isExpired(now: fixedDate.addingTimeInterval(HandoffRequest.maximumAge + 1)))
    }

    @Test func dictationURLRoundTrip() {
        let id = UUID()
        let url = DictationHandoff.dictationURL(sessionID: id)
        #expect(url.absoluteString == "kvoice://dictate?session=\(id.uuidString)")
        #expect(DictationHandoff.sessionID(from: url) == id)
        #expect(DictationHandoff.sessionID(from: URL(string: "kvoice://settings")!) == nil)
    }

    @Test func appStateExpiry() throws {
        let state = HandoffAppState(isListeningForCommands: true, updatedAt: fixedDate, expiresAt: fixedDate.addingTimeInterval(300))
        #expect(state.acceptsCommands(now: fixedDate.addingTimeInterval(299)))
        #expect(!state.acceptsCommands(now: fixedDate.addingTimeInterval(301)))
        #expect(!HandoffAppState(isListeningForCommands: false, updatedAt: fixedDate).acceptsCommands(now: fixedDate))
        // Files written before `expiresAt` existed still decode.
        let legacy = #"{"isListeningForCommands":true,"updatedAt":"2027-01-15T08:00:00Z"}"#
        let decoded = try DictationHandoff.decoder().decode(HandoffAppState.self, from: Data(legacy.utf8))
        #expect(decoded.expiresAt == nil && decoded.acceptsCommands(now: fixedDate))
    }

    @Test func commandExpiry() {
        let command = HandoffCommand(action: .start, sessionID: UUID(), createdAt: fixedDate)
        #expect(!command.isExpired(now: fixedDate.addingTimeInterval(10)))
        #expect(command.isExpired(now: fixedDate.addingTimeInterval(HandoffCommand.maximumAge + 1)))
    }

    @Test func appDictationURL() throws {
        let plain = DictationHandoff.appDictationURL()
        #expect(plain.absoluteString == "kvoice://dictate")
        #expect(DictationHandoff.isDictationURL(plain))
        #expect(DictationHandoff.sessionID(from: plain) == nil)
        let withMode = DictationHandoff.appDictationURL(modeID: Mode.BuiltInID.email)
        #expect(DictationHandoff.modeID(from: withMode) == Mode.BuiltInID.email)
        #expect(!DictationHandoff.isDictationURL(try #require(URL(string: "kvoice://settings"))))
    }

    @Test func missingFilesReadAsNil() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let handoff = DictationHandoff(directory: directory.url, postsNotifications: false)
        #expect(handoff.readRequest() == nil)
        #expect(handoff.readResult() == nil)
        #expect(handoff.readCommand() == nil)
    }

    @Test func notificationNamesAreDistinct() {
        let names: [DarwinNotificationName] = [
            .handoffRequest, .handoffCommand, .handoffResult, .handoffAppState,
            .modesChanged, .activeModeChanged, .settingsChanged
        ]
        #expect(Set(names).count == names.count)
    }
}
