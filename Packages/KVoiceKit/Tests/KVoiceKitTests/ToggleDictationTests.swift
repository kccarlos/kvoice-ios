import Foundation
import Testing
@testable import KVoiceCore

@Suite struct ToggleDictationTests {
    typealias Activity = DictationActivity
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let job = UUID()

    func activity(_ phase: Activity.Phase, lease: TimeInterval? = 60) -> Activity {
        Activity(phase: phase, leaseExpiresAt: phase.isIdle ? nil : t0.addingTimeInterval(lease ?? 0), updatedAt: t0)
    }

    // MARK: Source

    @Test func actionButtonSourceRoundTripsAndOldRecordsDecode() throws {
        #expect(Activity.Source.actionButton.rawValue == "actionButton")
        let phase = Activity.Phase.recording(owner: .app, source: .actionButton, startedAt: t0)
        let data = try JSONEncoder().encode(activity(phase))
        #expect(try JSONDecoder().decode(Activity.self, from: data).phase == phase)
        for raw in ["keyboard", "app", "intent", "shortcut"] {
            #expect(Activity.Source(rawValue: raw) != nil)
        }
    }

    // MARK: Route

    @Test func toggleRouteForEveryPhase() {
        let now = t0
        let cases: [(Activity.Phase, Activity.ToggleRoute)] = [
            (.idle, .start),
            (.standby(expiresAt: t0.addingTimeInterval(300)), .start),
            (.delivered(jobID: job), .start),
            (.failed(jobID: job, message: "x"), .start),
            (.recording(owner: .app, source: .app, startedAt: t0), .stop),
            (.recording(owner: .app, source: .keyboard, startedAt: t0), .stop),
            (.recording(owner: .app, source: .actionButton, startedAt: t0), .stop),
            (.recording(owner: .shortcut, source: .shortcut, startedAt: t0), .blocked(Activity.Message.shortcutRecordingApp)),
            (.processing(stage: .transcribing, jobID: job), .blocked(Activity.Message.busy)),
            (.processing(stage: .formatting, jobID: job), .blocked(Activity.Message.busy))
        ]
        for (phase, route) in cases {
            #expect(activity(phase, lease: 300).toggleRoute(now: now) == route)
        }
    }

    @Test func expiredLeaseTogglesAsIdle() {
        let recording = activity(.recording(owner: .app, source: .app, startedAt: t0), lease: 120)
        #expect(recording.toggleRoute(now: t0.addingTimeInterval(120)) == .start)
        let busy = activity(.processing(stage: .formatting, jobID: job), lease: 60)
        #expect(busy.toggleRoute(now: t0.addingTimeInterval(61)) == .start)
    }

    // MARK: Live status

    @Test func liveStatusMapsEveryPhase() {
        func status(_ phase: Activity.Phase, text: String? = nil) -> DictationLiveStatus? {
            DictationLiveStatus.from(phase: phase, modeName: "Clean", modeIcon: "sparkles", resultText: text)
        }
        #expect(status(.idle) == nil)
        #expect(status(.standby(expiresAt: t0)) == nil)
        #expect(status(.recording(owner: .app, source: .actionButton, startedAt: t0))?.stage == .recording(startedAt: t0))
        #expect(status(.processing(stage: .transcribing, jobID: job))?.stage == .transcribing)
        #expect(status(.processing(stage: .formatting, jobID: job))?.stage == .formatting)
        #expect(status(.delivered(jobID: job), text: "hello")?.stage == .done(preview: "hello"))
        #expect(status(.delivered(jobID: job))?.stage == .done(preview: ""))
        #expect(status(.failed(jobID: job, message: "no"))?.stage == .failed(message: "no"))
        #expect(status(.idle) == nil)
        let s = status(.processing(stage: .formatting, jobID: job))
        #expect(s?.modeName == "Clean")
        #expect(s?.modeIcon == "sparkles")
    }

    @Test func previewIsCutAtEightyCharacters() {
        let exact = String(repeating: "a", count: 80)
        #expect(DictationLiveStatus.preview(of: exact) == exact)
        #expect(DictationLiveStatus.preview(of: exact + "b") == exact + "…")
    }

    @Test func liveStatusRoundTrips() throws {
        let status = DictationLiveStatus(stage: .done(preview: "hi"), modeName: "M", modeIcon: "mic")
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(DictationLiveStatus.self, from: data) == status)
    }

    // MARK: Strategy

    @Test func strategyDefaultsAndPersists() {
        let test = TestDefaults()
        defer { test.cleanUp() }
        let defaults = test.defaults
        #expect(ToggleStartStrategy.current(defaults: defaults) == .returnImmediately)
        ToggleStartStrategy.set(.holdUntilStopped, defaults: defaults)
        #expect(ToggleStartStrategy.current(defaults: defaults) == .holdUntilStopped)
        defaults.set("bogus", forKey: ToggleStartStrategy.defaultsKey)
        #expect(ToggleStartStrategy.current(defaults: defaults) == .returnImmediately)
        #expect(ToggleStartStrategy.allCases.count == 2)
    }
}

@Suite struct DiagnosticsLogTests {
    @Test func appendReadClear() throws {
        let dir = try TempDirectory()
        defer { dir.cleanUp() }
        let log = DiagnosticsLog(directory: dir.url)
        #expect(log.read().isEmpty)
        log.append(category: "a", "one")
        log.append(category: "b", "two")
        #expect(log.read().map(\.message) == ["one", "two"])
        #expect(log.read().map(\.category) == ["a", "b"])
        log.clear()
        #expect(log.read().isEmpty)
    }

    @Test func keepsOnlyTheLast200() throws {
        let dir = try TempDirectory()
        defer { dir.cleanUp() }
        let log = DiagnosticsLog(directory: dir.url)
        for i in 0..<250 { log.append(category: "c", "m\(i)") }
        let entries = log.read()
        #expect(entries.count == DiagnosticsLog.capacity)
        #expect(entries.first?.message == "m50")
        #expect(entries.last?.message == "m249")
    }

    @Test func persistsAcrossInstancesAndSurvivesMultilineMessages() throws {
        let dir = try TempDirectory()
        defer { dir.cleanUp() }
        DiagnosticsLog(directory: dir.url).append(category: "c", "a\nb")
        #expect(DiagnosticsLog(directory: dir.url).read().map(\.message) == ["a\nb"])
    }

    @Test func concurrentAppendsAreAllKept() async throws {
        let dir = try TempDirectory()
        defer { dir.cleanUp() }
        let log = DiagnosticsLog(directory: dir.url)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 { group.addTask { log.append(category: "c", "m\(i)") } }
        }
        #expect(log.read().count == 40)
    }
}
