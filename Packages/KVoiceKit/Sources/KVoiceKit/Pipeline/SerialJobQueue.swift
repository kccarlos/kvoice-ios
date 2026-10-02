import Foundation

/// Runs dictation processing jobs one at a time, in the order they were
/// submitted. Each job runs in its caller's task, so cancelling the caller
/// cancels the job (a cancelled job that is still waiting starts and stops
/// at its first cancellation check).
@MainActor
public final class SerialJobQueue {
    private var tail: Task<Void, Never>?
    /// Jobs submitted and not finished (running and waiting).
    public private(set) var count = 0

    public init() {}

    public var isBusy: Bool { count > 0 }

    public func run<T>(_ work: () async throws -> T) async rethrows -> T {
        let previous = tail
        let (finished, signal) = AsyncStream<Void>.makeStream()
        tail = Task { for await _ in finished {} }
        count += 1
        defer {
            count -= 1
            signal.finish()
        }
        await previous?.value
        return try await work()
    }
}
