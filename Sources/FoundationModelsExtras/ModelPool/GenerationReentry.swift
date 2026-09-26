import Synchronization
import ULID

/// The queue of one model call, and the model of that queue.
public struct SubmissionTarget: Sendable {
    /// The queue that runs the call.
    public let queue: GenerationQueue

    /// The model of the queue.
    public let model: ModelRef

    /// Names the queue of a model call and its model.
    ///
    /// - Parameters:
    ///   - queue: The queue that runs the call.
    ///   - model: The model of the queue.
    public init(queue: GenerationQueue, model: ModelRef) {
        self.queue = queue
        self.model = model
    }
}

/// A task-local mark of one model call of a session.
///
/// The owner of a model call binds a mark to ``current`` around the call, and
/// calls ``close()`` when the call returns. Code inside the call, such as a
/// tool body, sees the open mark. ``GenerationQueue`` reads it to refuse a
/// job that could never start.
public final class ModelCallMark: Sendable {
    /// The mark of the current task, or `nil` outside a model call.
    @TaskLocal public static var current: ModelCallMark?

    /// The session of the model call.
    public let sessionID: ULID

    /// The queue and the model of the call, or `nil` when the call has no
    /// queue.
    public let submission: SubmissionTarget?

    /// Whether the model call has not returned yet.
    private let isOpen = Atomic(true)

    /// Makes an open mark for one model call.
    ///
    /// - Parameters:
    ///   - sessionID: The session of the model call.
    ///   - submission: The queue and the model of the call, or `nil` when the
    ///     call has no queue.
    public init(sessionID: ULID, submission: SubmissionTarget? = nil) {
        self.sessionID = sessionID
        self.submission = submission
    }

    /// Whether this mark is open and belongs to `sessionID`.
    ///
    /// - Parameter sessionID: The session to compare.
    /// - Returns: `true` for an open mark of that session.
    public func isOpenModelCall(of sessionID: ULID) -> Bool {
        sessionID == self.sessionID && isOpen.load(ordering: .acquiring)
    }

    /// The target of this mark when the mark is open and its call runs on
    /// `queue`.
    ///
    /// - Parameter queue: The queue of a new job.
    /// - Returns: The target, or `nil`.
    public func openSubmission(on queue: GenerationQueue) -> SubmissionTarget? {
        guard let submission, submission.queue === queue, isOpen.load(ordering: .acquiring) else { return nil }
        return submission
    }

    /// Closes the mark when the model call returns.
    public func close() {
        isOpen.store(false, ordering: .releasing)
    }

    /// Runs `body` under a closed copy of the current mark. A background run
    /// that a model call starts uses this, because it does not run inside
    /// that call. Outside a model call, `body` runs with no mark.
    ///
    /// - Parameter body: The work of the background run.
    /// - Returns: What `body` returns.
    public static func withBackgroundRunMark<T>(_ body: () async -> T) async -> T {
        let closed = current.map { ModelCallMark(sessionID: $0.sessionID, submission: $0.submission) }
        closed?.close()
        return await $current.withValue(closed) {
            await body()
        }
    }
}
