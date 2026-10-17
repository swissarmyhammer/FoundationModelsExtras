import Metrics
import Synchronization
import Tracing

/// A work queue in front of one shared model. One worker runs the jobs one at
/// a time, first in first out.
///
/// A job is one call to the model. A submitter waits only for the result of
/// its own job. When the submitter is cancelled, a waiting job never starts,
/// and a running job gets the cancel on its task.
///
/// A job runs on a task of its own, which inherits no task-local value of the
/// submitter. The job restores only the telemetry of the submitter around its
/// body: the trace context (`ServiceContext.current`), the tracer that
/// `withTracer` bound, and the metrics factory that `withMetricsFactory`
/// bound. Thus a span that the body opens has the span of the submitter as
/// its parent, and ``ModelCallMark/current`` is `nil` in the body.
public final class GenerationQueue: Sendable {
    /// The input of the worker loop.
    private let jobs: AsyncStream<any QueuedJob>.Continuation

    /// The number of jobs that are not finished: the running job and the
    /// waiting jobs.
    ///
    /// `submit` and `enqueue` count a job, put it in the worker input, and
    /// record the depth increment of the job under this one lock. Thus when
    /// ``waitingCount`` or the depth metric shows a job, each job that is
    /// submitted after that runs after it. Lock order: this lock, then the
    /// lock of a job, then the lock of the metrics backend. No code takes this
    /// lock while it holds the lock of a job.
    private let unfinished = Mutex<Int>(0)

    /// The recorder of the metrics of this queue: the depth, and the wait
    /// time, the run time and the count of each job.
    let telemetry: QueueTelemetry

    /// Makes an idle queue with the queue name
    /// ``QueueName/generation`` and no model, and starts its worker loop.
    public convenience init() {
        self.init(telemetry: QueueTelemetry(name: .generation))
    }

    /// Makes an idle queue and starts its worker loop.
    ///
    /// - Parameter telemetry: The recorder of the metrics of the queue. It
    ///   gives the queue name and the model of each metric.
    init(telemetry: QueueTelemetry) {
        self.telemetry = telemetry
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
                // Move the value into the continuation. `resume(with:)` only
                // borrows the result, so the job would keep a reference
                // after the submitter resumes.
                let jobsAhead = enqueue(job) { result in
                    switch consume result {
                    case .success(let value): continuation.resume(returning: consume value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                if let jobsAhead, jobsAhead > 0 {
                    onQueued()
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Puts `body` in the queue as one job, and returns at once. Nothing waits
    /// for the job, and nothing cancels it. A job that `submit` or `enqueue`
    /// puts in the queue after this call runs after this job.
    ///
    /// - Parameter body: The job.
    func enqueue(_ body: @escaping @Sendable () async -> Void) {
        _ = enqueue(Job(queue: self, priority: Task.currentPriority, body: body)) { _ in }
    }

    /// Counts `job`, puts it in the worker input, and records its depth
    /// increment, in one step under the lock of the count. A job that was
    /// cancelled first gets none of the three.
    ///
    /// - Parameters:
    ///   - job: The new job.
    ///   - resume: Gives the result of the job to its submitter.
    /// - Returns: The number of jobs ahead of `job`, or `nil` when the job was
    ///   cancelled first.
    private func enqueue<T>(_ job: Job<T>, resume: @escaping Job<T>.Resume) -> Int? {
        let jobsAhead = unfinished.withLock { count -> Int? in
            guard job.wait(resume) else { return nil }
            jobs.yield(job)
            job.recordAccepted()
            count += 1
            return count - 1
        }
        if jobsAhead == nil {
            job.refuse(resume)
        }
        return jobsAhead
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
        get async { unfinishedCount > 0 }
    }

    /// The number of jobs that wait behind the running job.
    public var waitingCount: Int {
        get async { max(unfinishedCount - 1, 0) }
    }

    /// The number of jobs that are not finished, read under the lock.
    private var unfinishedCount: Int {
        unfinished.withLock { $0 }
    }

    /// Subtracts one finished or cancelled job from the count. A job calls
    /// this only after it releases its own lock.
    fileprivate func releaseJobCount() {
        unfinished.withLock { $0 -= 1 }
    }
}

/// A job in the input of the worker loop.
private protocol QueuedJob: Sendable {
    /// Runs the job to its end. Does nothing when the job is finished.
    func run() async
}

/// One submission and its state. Each change of state occurs under one lock,
/// so exactly one path resumes the submitter. That same path records the
/// completion of the job, thus each job records its completion exactly one
/// time. The path records the metrics after it releases the lock.
private final class Job<T: Sendable>: QueuedJob {
    /// Gives the result of the job to its submitter. The resume takes the
    /// result, so the job keeps no reference to it after the submitter
    /// resumes. Thus when the submitter drops the result, that is its last
    /// reference.
    typealias Resume = @Sendable (consuming Result<T, any Error>) -> Void

    /// The steps of a job: new, then waiting, then running, then finished.
    private enum State: Sendable {
        case new
        case waiting(Resume)
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

    /// The queue ticket of the job. The job gets it when it is made, before
    /// the queue counts it, thus ``run()`` never sees a job with no ticket.
    /// The depth goes up only at ``recordAccepted()``.
    private let ticket: QueueTicket

    /// The trace context and the tracer of the submitter, from the enqueue.
    private let submitter: SubmitterTelemetry

    /// Makes a new job, and records nothing. Make the job on the task of the
    /// submitter: the ticket keeps the metrics factory of that task, and
    /// ``submitter`` keeps its trace context and its tracer.
    init(queue: GenerationQueue, priority: TaskPriority, body: @escaping @Sendable () async throws -> T) {
        self.queue = queue
        self.priority = priority
        self.body = body
        self.ticket = queue.telemetry.makeTicket()
        self.submitter = SubmitterTelemetry()
    }

    /// Records that the queue accepted the job: the depth goes up by one.
    /// The queue calls this one time, in the step that counts the job.
    func recordAccepted() {
        queue.telemetry.accepted(ticket)
    }

    /// Keeps the resume of the submitter. The caller counts the job.
    ///
    /// - Parameter resume: Gives the result of the job to its submitter.
    /// - Returns: `true` when the job now waits, or `false` when the job was
    ///   cancelled first. Then the caller calls ``refuse(_:)`` after it
    ///   releases the lock of the count.
    func wait(_ resume: @escaping Resume) -> Bool {
        state.withLock { state -> Bool in
            guard case .new = state else { return false }
            state = .waiting(resume)
            return true
        }
    }

    /// Records a job that was cancelled before it waited as cancelled, with
    /// no depth change, and gives `CancellationError` to its submitter. Call
    /// this only when ``wait(_:)`` returned `false`: then ``cancel()``
    /// finished the job and recorded nothing, and the queue never accepted
    /// the job.
    ///
    /// - Parameter resume: Gives the result of the job to its submitter.
    func refuse(_ resume: Resume) {
        queue.telemetry.refused(ticket)
        resume(.failure(CancellationError()))
    }

    /// Records a waiting job that was cancelled as cancelled, with no run
    /// time, and gives `CancellationError` to its submitter. The queue
    /// accepted the job, thus the depth goes down.
    ///
    /// - Parameter resume: Gives the result of the job to its submitter.
    private func finishCancelledWhileWaiting(_ resume: Resume) {
        queue.telemetry.completed(ticket, outcome: .cancelled)
        resume(.failure(CancellationError()))
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
        case .waiting(let resume):
            // Release the count before completed: its lock keeps the decrement after recordAccepted().
            queue.releaseJobCount()
            finishCancelledWhileWaiting(resume)
        case .running(let task):
            task.cancel()
        case .new, .finished:
            break
        }
    }

    /// Runs the job on a new detached task, and waits for it. Only the worker
    /// loop calls this.
    ///
    /// The detached task inherits no task-local of the submitter. Thus
    /// ``ModelCallMark/current`` and each other task-local of the submitter
    /// stay out of the job. The task restores only the trace context and the
    /// tracer of ``submitter``, and the metrics factory of the ticket, around
    /// the body.
    func run() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard case .waiting(let resume) = state else { return nil }
            let started = recordStart()
            let task = Task.detached(priority: priority) {
                let result = await self.submitter.restore(factory: started.factory) {
                    await self.runBody()
                }
                self.finish(result: result, ticket: started)
                resume(consume result)
            }
            state = .running(task)
            return task
        }
        await task?.value
    }

    /// Runs the body of the job.
    ///
    /// - Returns: The value of the body, or the error that it threw.
    private func runBody() async -> Result<T, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// Records in the telemetry that the job starts now.
    ///
    /// - Returns: A copy of the ticket of the job, with the start instant.
    private func recordStart() -> QueueTicket {
        var started = ticket
        queue.telemetry.started(&started)
        return started
    }

    /// Marks the running job as finished, and records its completion,
    /// before its submitter resumes.
    ///
    /// - Parameters:
    ///   - result: The result of the body of the job.
    ///   - started: The ticket of the job, with the start instant.
    private func finish(result: Result<T, any Error>, ticket started: QueueTicket) {
        state.withLock { $0 = .finished }
        // Release the count before completed: its lock keeps the decrement after recordAccepted().
        queue.releaseJobCount()
        queue.telemetry.completed(started, outcome: QueueOutcome(of: result))
    }
}

/// The trace context and the tracer of the task that submits a job. The job
/// restores them around its body, on a detached task that inherits neither.
///
/// The job restores no other task-local of the submitter. Thus
/// ``ModelCallMark/current`` stays `nil` in the body.
private struct SubmitterTelemetry: Sendable {
    /// The trace context of the submitter, or `nil` when it had none.
    private let context: ServiceContext?

    /// The active tracer of the submitter: the tracer that `withTracer`
    /// bound, or else the bootstrapped instrument when it is a tracer. It is
    /// `nil` when the active instrument is not a tracer. Then the job binds
    /// no tracer, and sees the same bootstrapped instrument.
    private let tracer: (any Tracer)?

    /// Reads the trace context and the active tracer of the current task.
    /// Call this on the task of the submitter.
    init() {
        context = ServiceContext.current
        // `withTracer` accepts only a `Tracer`, thus a task-local instrument
        // is always a tracer. The task-local itself is not public, but
        // `instrument` gives it first.
        tracer = InstrumentationSystem.instrument as? any Tracer
    }

    /// Runs `body` with the trace context, the tracer and `factory` bound as
    /// the task-local values of the current task.
    ///
    /// - Parameters:
    ///   - factory: The metrics factory of the submitter, from the ticket of
    ///     the job.
    ///   - body: The work to run.
    /// - Returns: What `body` returns.
    func restore<Value>(factory: any MetricsFactory, _ body: () async -> Value) async -> Value {
        await withMetricsFactory(factory) {
            await ServiceContext.withValue(context) {
                guard let tracer else { return await body() }
                return await withTracer(tracer) { await body() }
            }
        }
    }
}
