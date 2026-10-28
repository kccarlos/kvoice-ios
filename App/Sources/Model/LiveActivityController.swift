import ActivityKit
import Foundation
import KVoiceKit

/// Mirrors the shared `DictationActivity` into a Live Activity, best effort.
///
/// Activities are only requested from `ToggleDictationIntent` (before it
/// touches the microphone, as audio recording intents require) and from a
/// recording the app starts in the foreground; background requests from
/// anywhere else fail. Updates and ends follow every activity change.
/// Every error goes to `DiagnosticsLog`.
@MainActor
final class LiveActivityController {
    typealias Live = Activity<DictationActivityAttributes>

    /// The result text of the dictation that just finished (for the "Copied"
    /// preview); set by `HandoffCoordinator` before the job settles.
    var resultText: String?

    /// The activity this controller owns. Its attribute `sessionID` is fixed
    /// when it is created, so a reused activity (standby taken over by a new
    /// session) is tracked by `currentSessionID` instead.
    private var current: Live?
    /// The session `current` represents now.
    private var currentSessionID: UUID?
    private var lastStatus: DictationLiveStatus?
    private let log = DiagnosticsLog.shared

    /// How long a finished or failed activity stays on screen.
    static let dismissDelay: TimeInterval = 4

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: Request

    /// Requests the activity for a recording that is about to start.
    /// The request goes first: from a background intent it can fail, and then
    /// the standby activity is reused (updated to recording) rather than lost,
    /// because an audio recording intent needs a Live Activity. Old
    /// activities end only after the new one is secured.
    /// Returns whether there is a live activity for the session, requested
    /// or reused.
    @discardableResult
    func start(sessionID: UUID, modeName: String, modeIcon: String, allowsReuse: Bool = true) -> Bool {
        guard isEnabled else {
            log.append(category: "liveactivity", "request skipped: activities disabled")
            return false
        }
        let status = DictationLiveStatus(stage: .recording(startedAt: .now), modeName: modeName, modeIcon: modeIcon)
        let existing = current ?? Live.activities.first
        do {
            let live = try Live.request(
                attributes: DictationActivityAttributes(sessionID: sessionID),
                content: ActivityContent(state: status, staleDate: nil),
                pushType: nil
            )
            current = live
            currentSessionID = sessionID
            lastStatus = status
            log.append(category: "liveactivity", "request ok")
            // A standby activity from the previous session gives way.
            for old in Live.activities where old.id != live.id {
                Self.end(id: old.id, content: nil, policy: .immediate)
            }
            return true
        } catch {
            log.append(category: "liveactivity", "request failed \(Self.describe(error))")
            guard allowsReuse, let existing else { return false }
            log.append(category: "liveactivity", "request failed, reusing existing")
            current = existing
            currentSessionID = sessionID
            lastStatus = status
            Self.update(id: existing.id, content: ActivityContent(state: status, staleDate: nil))
            for other in Live.activities where other.id != existing.id {
                Self.end(id: other.id, content: nil, policy: .immediate)
            }
            return true
        }
    }

    // MARK: Mirror

    /// Follows an activity change: update, or end when the phase has no
    /// status (idle). A job that settles into standby updates the activity
    /// instead of ending it. Never requests.
    func sync(_ activity: DictationActivity, mode: Mode) {
        let phase = activity.effectivePhase(now: .now)
        guard let status = DictationLiveStatus.from(
            phase: phase, modeName: mode.name, modeIcon: mode.icon, resultText: resultText
        ) else {
            resultText = nil
            if current != nil || !Live.activities.isEmpty { endAll(except: nil) }
            return
        }
        if liveActivity(for: activity.id) == nil, current != nil {
            // A session someone else started (keyboard) took over the standby
            // activity; it cannot be requested here, so reuse it.
            currentSessionID = activity.id
        }
        guard let live = liveActivity(for: activity.id) else { return }
        guard status != lastStatus else { return }
        lastStatus = status
        let content = ActivityContent(state: status, staleDate: nil)
        switch status.stage {
        case .done, .failed:
            forgetCurrent()
            resultText = nil
            Self.end(id: live.id, content: content, policy: .after(.now.addingTimeInterval(Self.dismissDelay)))
        default:
            Self.update(id: live.id, content: content)
        }
    }

    private func liveActivity(for sessionID: UUID) -> Live? {
        if let current, currentSessionID == sessionID { return current }
        return Live.activities.first { $0.attributes.sessionID == sessionID }
    }

    // MARK: End

    /// Ends the activity of one session at once.
    func end(sessionID: UUID) {
        var ids: Set<String> = []
        if let current, currentSessionID == sessionID { ids.insert(current.id) }
        for live in Live.activities where live.attributes.sessionID == sessionID { ids.insert(live.id) }
        if currentSessionID == sessionID { forgetCurrent() }
        for id in ids { Self.end(id: id, content: nil, policy: .immediate) }
    }

    /// Ends every activity except the one for `keeping`.
    func endAll(except keeping: UUID?) {
        let keepID = keeping != nil && currentSessionID == keeping ? current?.id : nil
        for live in Live.activities where live.id != keepID && (keeping == nil || live.attributes.sessionID != keeping) {
            Self.end(id: live.id, content: nil, policy: .immediate)
        }
        if currentSessionID != keeping { forgetCurrent() }
    }

    private func forgetCurrent() {
        current = nil
        currentSessionID = nil
        lastStatus = nil
    }

    /// Launch cleanup: a previous process may have left activities behind.
    /// Keeps only the one that belongs to a recording or job still alive,
    /// including a reused one whose attribute names an older session.
    func appLaunched(activity: DictationActivity) {
        let phase = activity.effectivePhase(now: .now)
        var keeping: UUID?
        switch phase {
        case .recording, .processing: keeping = activity.id
        default: break
        }
        let count = Live.activities.count
        if count > 0 { log.append(category: "liveactivity", "launch cleanup count=\(count) keeping=\(keeping != nil)") }
        if let keeping, current == nil,
           let live = Live.activities.first(where: { $0.attributes.sessionID == keeping }) ?? Live.activities.first {
            current = live
            currentSessionID = keeping
        }
        endAll(except: keeping)
    }

    // ActivityKit's async calls are nonisolated; going through the id keeps
    // the activity itself on the main actor.
    private static func end(
        id: String, content: ActivityContent<DictationLiveStatus>?, policy: ActivityUIDismissalPolicy
    ) {
        Task.detached {
            for live in Live.activities where live.id == id { await live.end(content, dismissalPolicy: policy) }
        }
    }

    private static func update(id: String, content: ActivityContent<DictationLiveStatus>) {
        Task.detached {
            for live in Live.activities where live.id == id { await live.update(content) }
        }
    }

    /// Domain and code, never the message (it may carry user data).
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "domain=\(ns.domain) code=\(ns.code)"
    }
}
