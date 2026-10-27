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

    private var current: Live?
    private var lastStatus: DictationLiveStatus?
    private let log = DiagnosticsLog.shared

    /// How long a finished or failed activity stays on screen.
    static let dismissDelay: TimeInterval = 4

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: Request

    /// Requests the activity for a recording that is about to start.
    /// Returns whether it was granted.
    @discardableResult
    func start(sessionID: UUID, modeName: String, modeIcon: String) -> Bool {
        guard isEnabled else {
            log.append(category: "liveactivity", "request skipped: activities disabled")
            return false
        }
        let status = DictationLiveStatus(stage: .recording(startedAt: .now), modeName: modeName, modeIcon: modeIcon)
        do {
            current = try Live.request(
                attributes: DictationActivityAttributes(sessionID: sessionID),
                content: ActivityContent(state: status, staleDate: nil),
                pushType: nil
            )
            lastStatus = status
            log.append(category: "liveactivity", "request ok")
            return true
        } catch {
            log.append(category: "liveactivity", "request failed \(Self.describe(error))")
            return false
        }
    }

    // MARK: Mirror

    /// Follows an activity change: update, or end when the phase has no
    /// status (idle, standby). Never requests.
    func sync(_ activity: DictationActivity, mode: Mode) {
        let phase = activity.effectivePhase(now: .now)
        guard let status = DictationLiveStatus.from(
            phase: phase, modeName: mode.name, modeIcon: mode.icon, resultText: resultText
        ) else {
            if current != nil || !Live.activities.isEmpty { endAll(except: nil) }
            return
        }
        guard let live = liveActivity(for: activity.id), status != lastStatus else { return }
        lastStatus = status
        let content = ActivityContent(state: status, staleDate: nil)
        switch status.stage {
        case .done, .failed:
            current = nil
            lastStatus = nil
            resultText = nil
            Self.end(id: live.id, content: content, policy: .after(.now.addingTimeInterval(Self.dismissDelay)))
        default:
            Self.update(id: live.id, content: content)
        }
    }

    private func liveActivity(for sessionID: UUID) -> Live? {
        if let current, current.attributes.sessionID == sessionID { return current }
        return Live.activities.first { $0.attributes.sessionID == sessionID }
    }

    // MARK: End

    /// Ends the activity of one session at once.
    func end(sessionID: UUID) {
        if current?.attributes.sessionID == sessionID {
            current = nil
            lastStatus = nil
        }
        for live in Live.activities where live.attributes.sessionID == sessionID {
            Self.end(id: live.id, content: nil, policy: .immediate)
        }
    }

    /// Ends every activity except the one for `keeping`.
    func endAll(except keeping: UUID?) {
        for live in Live.activities where live.attributes.sessionID != keeping {
            Self.end(id: live.id, content: nil, policy: .immediate)
        }
        if current?.attributes.sessionID != keeping {
            current = nil
            lastStatus = nil
        }
    }

    /// Launch cleanup: a previous process may have left activities behind.
    /// Keeps only the one that belongs to a recording or job still alive.
    func appLaunched(activity: DictationActivity) {
        let phase = activity.effectivePhase(now: .now)
        var keeping: UUID?
        switch phase {
        case .recording, .processing: keeping = activity.id
        default: break
        }
        let count = Live.activities.count
        if count > 0 { log.append(category: "liveactivity", "launch cleanup count=\(count) keeping=\(keeping != nil)") }
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
