import Synchronization

/// A work queue in front of one shared model. One worker runs the jobs one at
/// a time, first in first out.
///
/// A job is one call to the model. A submitter waits only for the result of
/// its own job. When the submitter is cancelled, a waiting job never starts,
/// and a running job gets the cancel on its task.
public final class GenerationQueue: Sendable {
    /// The input of the worker loop.
    private let jobs: AsyncStream<any QueuedJob>.Continuation

    /// The number of jobs that are not finished: the running job and the
    /// waiting jobs.
    fileprivate let unfinished = Atomic<Int>(0)

    /// Makes an idle queue and starts its worker loop.
    public init() {
        let (stream, jobs) = AsyncStream.makeStream(of: (any QueuedJob).self)
        self.jobs = jobs
        Task.detached {
            for await job in stream {
                await job.run()
            }
        }
    }

    /// Stops the worker loop.
    deinit {
        jobs.finish()
    }

    /// Runs `body` as one job, and waits for its result. This is
    /// ``submit(isolation:onQueued:_:)`` with no `onQueued`.
    public func submit<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await submit(isolation: isolation, onQueued: {}, body)
    }

    /// Runs `body` as one job, and waits for its result. Calls `onQueued`
    /// first when the job must wait behind another job.
    ///
    /// - Parameters:
    ///   - isolation: The actor isolation of the caller. The caller waits there.
    ///   - onQueued: Called on the caller when the job must wait.
    ///   - body: The job.
    /// - Returns: What `body` returns.
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)``,
    ///   `CancellationError` when the caller is cancelled before the job
    ///   starts, or what `body` throws.
    public func submit<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        onQueued: @Sendable () -> Void,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try refuseWaitInsideOpenSubmission()
        let job = Job(queue: self, priority: Task.currentPriority, body: body)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard let jobsAhead = job.wait(continuation) else { return }
                if jobsAhead > 0 {
                    onQueued()
                }
                jobs.yield(job)
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Throws when the current task is inside an open model call on this
    /// queue. A job from that task waits behind the call that waits for it,
    /// so it can never start.
    ///
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    public func refuseWaitInsideOpenSubmission() throws {
        guard let open = ModelCallMark.current?.openSubmission(on: self) else { return }
        throw GenerationQueueError.waitInsideOpenSubmission(model: open.model)
    }

    /// Whether a job runs or waits.
    public var isRunning: Bool {
        get async { unfinished.load(ordering: .sequentiallyConsistent) > 0 }
    }

    /// The number of jobs that wait behind the running job.
    public var waitingCount: Int {
        get async { max(unfinished.load(ordering: .sequentiallyConsistent) - 1, 0) }
    }
}

/// A job in the input of the worker loop.
private protocol QueuedJob: Sendable {
    /// Runs the job to its end. Does nothing when the job is finished.
    func run() async
}

/// One submission and its state. Each change of state occurs under one lock,
/// so exactly one path resumes the submitter.
private final class Job<T: Sendable>: QueuedJob {
    /// The steps of a job: new, then waiting, then running, then finished.
    private enum State: Sendable {
        case new
        case waiting(CheckedContinuation<T, any Error>)
        case running(Task<Void, Never>)
        case finished
    }

    /// The queue that counts this job.
    private let queue: GenerationQueue

    /// The priority of the submitter.
    private let priority: TaskPriority

    /// The work of the job.
    private let body: @Sendable () async throws -> T

    /// The state of the job.
    private let state = Mutex(State.new)

    /// Makes a new job.
    init(queue: GenerationQueue, priority: TaskPriority, body: @escaping @Sendable () async throws -> T) {
        self.queue = queue
        self.priority = priority
        self.body = body
    }

    /// Keeps the continuation of the submitter, and counts the job.
    ///
    /// - Parameter continuation: The continuation of the submitter.
    /// - Returns: The number of unfinished jobs before this one, or `nil`
    ///   when the job was cancelled first. Then the submitter gets
    ///   `CancellationError` at once.
    func wait(_ continuation: CheckedContinuation<T, any Error>) -> Int? {
        let jobsAhead = state.withLock { state -> Int? in
            guard case .new = state else { return nil }
            state = .waiting(continuation)
            return queue.unfinished.add(1, ordering: .sequentiallyConsistent).oldValue
        }
        if jobsAhead == nil {
            continuation.resume(throwing: CancellationError())
        }
        return jobsAhead
    }

    /// Cancels the job on the task that calls it, with no wait. A job that
    /// did not start is finished, and its submitter gets `CancellationError`.
    /// A running job gets the cancel on its task.
    func cancel() {
        let previous = state.withLock { state -> State in
            let previous = state
            if case .running = state { return previous }
            state = .finished
            return previous
        }
        switch previous {
        case .waiting(let continuation):
            queue.unfinished.subtract(1, ordering: .sequentiallyConsistent)
            continuation.resume(throwing: CancellationError())
        case .running(let task):
            task.cancel()
        case .new, .finished:
            break
        }
    }

    /// Runs the job on a new detached task, which inherits no task-local of
    /// the submitter, and waits for it. Only the worker loop calls this.
    func run() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard case .waiting(let continuation) = state else { return nil }
            let task = Task.detached(priority: priority) {
                let result: Result<T, any Error>
                do {
                    result = .success(try await self.body())
                } catch {
                    result = .failure(error)
                }
                self.finish()
                continuation.resume(with: result)
            }
            state = .running(task)
            return task
        }
        await task?.value
    }

    /// Marks the running job as finished, before its submitter resumes.
    private func finish() {
        state.withLock { $0 = .finished }
        queue.unfinished.subtract(1, ordering: .sequentiallyConsistent)
    }
}
