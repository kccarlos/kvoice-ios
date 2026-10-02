import Foundation
import Synchronization

/// Cross-process notification names shared by the app and the keyboard.
/// Darwin notifications carry no payload: the receiver reads state from the
/// App Group after it is woken.
public struct DarwinNotificationName: RawRepresentable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    private static let prefix = "io.github.kccarlos.kvoice.ios."

    /// The keyboard wrote a new `HandoffRequest`.
    public static let handoffRequest = Self(rawValue: prefix + "handoff.request")
    /// The keyboard wrote a `HandoffCommand` (start/stop/cancel).
    public static let handoffCommand = Self(rawValue: prefix + "handoff.command")
    /// The app updated the `HandoffResult` (status change or final text).
    public static let handoffResult = Self(rawValue: prefix + "handoff.result")
    /// The app's background-recording availability changed.
    public static let handoffAppState = Self(rawValue: prefix + "handoff.appState")
    /// The shared `DictationActivity` changed (who owns the microphone).
    public static let dictationActivity = Self(rawValue: prefix + "activity")
    /// Modes were added, edited, deleted or reordered.
    public static let modesChanged = Self(rawValue: prefix + "modes.changed")
    /// The active mode changed.
    public static let activeModeChanged = Self(rawValue: prefix + "modes.active")
    /// Settings changed.
    public static let settingsChanged = Self(rawValue: prefix + "settings.changed")
}

public enum DarwinNotifications {
    public static func post(_ name: DarwinNotificationName) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name.rawValue as CFString),
            nil, nil, true
        )
    }

    /// Calls `handler` (on an arbitrary thread) every time `name` is posted,
    /// by any process, until the returned observer is cancelled or released.
    public static func observe(
        _ name: DarwinNotificationName,
        handler: @escaping @Sendable () -> Void
    ) -> DarwinNotificationObserver {
        DarwinNotificationObserver(name: name, handler: handler)
    }

    /// An async stream of posts of `name`; ends when the consuming task is
    /// cancelled.
    public static func notifications(_ name: DarwinNotificationName) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = observe(name) { continuation.yield() }
            continuation.onTermination = { _ in observer.cancel() }
        }
    }
}

/// Keeps a Darwin notification registration alive.
public final class DarwinNotificationObserver: Sendable {
    public let name: DarwinNotificationName
    private let handler: @Sendable () -> Void
    private let registered = Mutex(false)

    init(name: DarwinNotificationName, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        registered.withLock { $0 = true }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinNotificationObserver>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .fire()
            },
            name.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func fire() {
        guard registered.withLock({ $0 }) else { return }
        handler()
    }

    public func cancel() {
        let wasRegistered = registered.withLock { value in
            defer { value = false }
            return value
        }
        guard wasRegistered else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name.rawValue as CFString),
            nil
        )
    }

    deinit { cancel() }
}
