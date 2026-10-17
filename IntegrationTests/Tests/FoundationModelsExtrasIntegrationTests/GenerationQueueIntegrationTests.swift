import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

/// The most tokens of a short answer: a capital city in one sentence.
private let shortAnswerTokens = 32

/// The most tokens of the long first job of a queue test. The job runs for
/// some seconds, thus the jobs after it are in the queue before it ends.
private let longAnswerTokens = 256

/// The token limit of the generation that the test cancels. The model cannot
/// finish the prompt early, and at the decode rate of the 1B model the limit is
/// far past the cancel.
private let cancelledGenerationTokens = 2048

/// The number of stream snapshots of the cancelled generation before the
/// cancel. Then the prefill is done, and the decode is on the GPU.
private let snapshotsBeforeCancel = 8

/// The divisor of the token limit that gives the most characters of the
/// cancelled generation. Each token of the count adds at least one character,
/// thus a generation to the limit gives more characters than the limit. A
/// cancel that stops the decode gives far fewer.
private let farBelowTheLimitDivisor = 4

/// A long question whose answer names Paris.
private let longParisPrompt = "Describe Paris, the capital city of France, in at least ten sentences."

/// A question that the model answers until its token limit.
private let endlessPrompt = "Count upward from 1, one number per line, without stopping."

/// A short question and the city that its answer names.
private struct CapitalQuestion {
    /// The question.
    let prompt: String
    /// The city that a real answer contains.
    let city: String
}

/// The short question of the tests that need one real answer.
private let franceQuestion = CapitalQuestion(prompt: "What is the capital city of France?", city: "Paris")

/// The three questions of the order test, in the order of their jobs.
private let orderedQuestions = [
    CapitalQuestion(prompt: longParisPrompt, city: "Paris"),
    CapitalQuestion(prompt: "What is the capital city of Japan?", city: "Tokyo"),
    CapitalQuestion(prompt: "What is the capital city of Italy?", city: "Rome"),
]

extension RealModelSuites {
    /// The `GenerationQueue` of a hold of the real LLM: one generation at a
    /// time on the GPU, the cancel of a job, and the refusal of a job that
    /// could never start.
    @Suite("Generation queue with a real model")
    struct GenerationQueueIntegrationTests {
        @Test("concurrent generations on one queue run one at a time, first in first out, and each gives a real answer")
        func concurrentGenerationsRunOneAtATimeInOrder() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let log = EventLog<String>()

            let answers = try await Self.withLLM(in: pool) { queue, model in
                let paris = await Self.startRunning(on: queue) {
                    try await JobLog.run(orderedQuestions[0], with: model, maximumResponseTokens: longAnswerTokens, into: log)
                }
                let tokyo = await Self.startQueued(on: queue) {
                    try await JobLog.run(orderedQuestions[1], with: model, maximumResponseTokens: shortAnswerTokens, into: log)
                }
                let rome = await Self.startQueued(on: queue) {
                    try await JobLog.run(orderedQuestions[2], with: model, maximumResponseTokens: shortAnswerTokens, into: log)
                }
                return try await [paris.value, tokyo.value, rome.value]
            }

            let cities = orderedQuestions.map(\.city)
            #expect(zip(answers, cities).allSatisfy { $0.contains($1) }, "answers: \(answers)")
            #expect(await log.events == cities.flatMap { [JobLog.start(of: $0), JobLog.end(of: $0)] })
        }

        @Test("a cancelled job that waits in the queue never starts, and the running job still gives its answer")
        func cancelledWaitingJobNeverStarts() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let starts = EventLog<String>()

            let outcome = try await Self.withLLM(in: pool) { queue, model in
                let paris = await Self.startRunning(on: queue) {
                    try await Generation.respond(to: longParisPrompt, with: model, maximumResponseTokens: longAnswerTokens)
                }
                let waiting = await Self.startQueued(on: queue) { await starts.append("the cancelled job") }
                waiting.cancel()
                let waitingCountAfterCancel = await queue.waitingCount
                let answer = try await paris.value
                // A later job runs after the worker of the queue reaches the cancelled job.
                try await queue.submit { await starts.append("the later job") }
                return WaitingCancelOutcome(
                    cancelled: await waiting.result, waitingCountAfterCancel: waitingCountAfterCancel, answer: answer)
            }

            #expect(throws: CancellationError.self) { try outcome.cancelled.get() }
            #expect(outcome.waitingCountAfterCancel == 0)
            #expect(outcome.answer.contains(franceQuestion.city), "answer: \(outcome.answer)")
            #expect(await starts.events == ["the later job"])
        }

        @Test("a cancel of the running real generation stops it well before its token limit, and the next job then runs")
        func cancelledRunningGenerationStopsEarly() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let snapshots = EventLog<String>()

            let outcome = try await Self.withLLM(in: pool) { queue, model in
                let running = Task {
                    try await queue.submit {
                        try await Generation.stream(
                            endlessPrompt, with: model, maximumResponseTokens: cancelledGenerationTokens, into: snapshots)
                    }
                }
                // The decode runs when the stream gave some snapshots. A
                // generation that ends first also ends the wait.
                await Waits.untilFirstEnds(
                    { await snapshots.waitUntil { $0.count >= snapshotsBeforeCancel } },
                    { _ = await running.result })
                let snapshotsAtCancel = await snapshots.events.count
                running.cancel()
                let cancelled = await running.result
                let next = try await queue.submit {
                    try await Generation.respond(to: franceQuestion.prompt, with: model, maximumResponseTokens: shortAnswerTokens)
                }
                return RunningCancelOutcome(
                    cancelled: cancelled, snapshotsAtCancel: snapshotsAtCancel,
                    generatedText: await snapshots.events.last ?? "", nextAnswer: next)
            }

            #expect(outcome.snapshotsAtCancel >= snapshotsBeforeCancel)
            #expect(throws: CancellationError.self) { try outcome.cancelled.get() }
            #expect(
                outcome.generatedText.count < cancelledGenerationTokens / farBelowTheLimitDivisor,
                "the cancelled generation gave \(outcome.generatedText.count) characters")
            #expect(outcome.nextAnswer.contains(franceQuestion.city), "answer: \(outcome.nextAnswer)")
        }

        @Test("a job that submits to its own queue from inside an open model call gets waitInsideOpenSubmission, and never waits")
        func submissionInsideAnOpenModelCallIsRefused() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let log = EventLog<String>()

            let outcome = try await Self.withLLM(in: pool) { queue, model in
                try await queue.submit {
                    try await ReentryOutcome.run(on: queue, with: model, log: log)
                }
            }

            #expect(
                outcome.refusal as? GenerationQueueError == .waitInsideOpenSubmission(model: IntegrationModels.llm.ref),
                "refusal: \(String(describing: outcome.refusal))")
            #expect(!outcome.waitedInTheQueue)
            #expect(await log.events == [ReentryOutcome.refusedEvent])
            #expect(outcome.answer.contains(franceQuestion.city), "answer: \(outcome.answer)")
        }

        /// Acquires the LLM in `pool`, runs `body` with the queue and the model
        /// of the hold, releases the hold, and waits for the eviction.
        private static func withLLM<T: Sendable>(
            in pool: ModelPool, _ body: (GenerationQueue, any LanguageModel) async throws -> T
        ) async throws -> T {
            let result = try await useLLM(in: pool, body)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.llm, in: pool)
            return result
        }

        /// Acquires the LLM in `pool`, and runs `body`. The hold goes when this
        /// function returns.
        private static func useLLM<T: Sendable>(
            in pool: ModelPool, _ body: (GenerationQueue, any LanguageModel) async throws -> T
        ) async throws -> T {
            let hold = try await IntegrationModels.acquire(key: IntegrationModels.llm, in: pool)
            let model = try Generation.languageModel(of: hold)
            let result = try await body(hold.queue, model)
            withExtendedLifetime(hold) {}
            return result
        }

        /// Submits `body` to the idle `queue` on a new task, and returns when
        /// the job runs, or when the submission ended first.
        ///
        /// - Parameters:
        ///   - queue: The queue. No job runs or waits in it.
        ///   - body: The job.
        /// - Returns: The task of the submission.
        private static func startRunning<T: Sendable>(
            on queue: GenerationQueue, _ body: @escaping @Sendable () async throws -> T
        ) async -> Task<T, any Error> {
            let running = Latch()
            let submission = Task {
                try await queue.submit {
                    running.open()
                    return try await body()
                }
            }
            await Waits.untilFirstEnds({ await running.waitUntilOpen() }, { _ = await submission.result })
            return submission
        }

        /// Submits `body` to `queue` on a new task, and returns when the job
        /// waits in the queue, or when the submission ended first. The queue
        /// calls `onQueued` after it put the job in the queue behind the jobs
        /// before it, thus the jobs of this function go into the queue in the
        /// order of the calls.
        ///
        /// - Parameters:
        ///   - queue: The queue. A job runs in it.
        ///   - body: The job.
        /// - Returns: The task of the submission.
        private static func startQueued<T: Sendable>(
            on queue: GenerationQueue, _ body: @escaping @Sendable () async throws -> T
        ) async -> Task<T, any Error> {
            let queued = Latch()
            let submission = Task { try await queue.submit(onQueued: { queued.open() }, body) }
            await Waits.untilFirstEnds({ await queued.waitUntilOpen() }, { _ = await submission.result })
            return submission
        }
    }
}

/// One generation job that writes its start and its end to a log.
private enum JobLog {
    /// The event that the job of `city` writes when it starts.
    static func start(of city: String) -> String { "start \(city)" }

    /// The event that the job of `city` writes when it ends.
    static func end(of city: String) -> String { "end \(city)" }

    /// Writes the start, runs one generation, and writes the end.
    ///
    /// - Parameters:
    ///   - question: The question and the city of its answer.
    ///   - model: The LLM.
    ///   - maximumResponseTokens: The most tokens of the answer.
    ///   - log: Gets the start and the end.
    /// - Returns: The text of the answer.
    /// - Throws: The error of the generation.
    static func run(
        _ question: CapitalQuestion, with model: any LanguageModel, maximumResponseTokens: Int,
        into log: EventLog<String>
    ) async throws -> String {
        await log.append(start(of: question.city))
        let answer = try await Generation.respond(
            to: question.prompt, with: model, maximumResponseTokens: maximumResponseTokens)
        await log.append(end(of: question.city))
        return answer
    }
}

/// What the test of the cancel of a waiting job observed.
private struct WaitingCancelOutcome: Sendable {
    /// The result of the submitter of the cancelled job.
    let cancelled: Result<Void, any Error>
    /// The waiting count of the queue just after the cancel.
    let waitingCountAfterCancel: Int
    /// The answer of the running job.
    let answer: String
}

/// What the test of the cancel of the running job observed.
private struct RunningCancelOutcome: Sendable {
    /// The result of the submitter of the cancelled generation.
    let cancelled: Result<String, any Error>
    /// The number of stream snapshots before the cancel.
    let snapshotsAtCancel: Int
    /// The text of the last snapshot of the cancelled generation.
    let generatedText: String
    /// The answer of the job after the cancelled one.
    let nextAnswer: String
}

/// What a job that submits to its own queue inside an open model call observed.
private struct ReentryOutcome: Sendable {
    /// The event that the log gets when the queue refuses the inner job.
    static let refusedEvent = "the inner submission was refused"

    /// The event that the log gets when the inner job runs.
    static let ranEvent = "the inner job ran"

    /// The real answer of the model call.
    let answer: String
    /// The error of the inner submission, or `nil` when the queue accepted it.
    let refusal: (any Error)?
    /// Whether the inner job waited in the queue behind the open call.
    let waitedInTheQueue: Bool

    /// Opens a model call on `queue`, gets a real answer in it, and then
    /// submits a job to `queue` from inside the open call. Run this inside a
    /// job of `queue`.
    ///
    /// - Parameters:
    ///   - queue: The queue of the job that runs this function.
    ///   - model: The LLM.
    ///   - log: Gets ``refusedEvent`` or ``ranEvent``.
    /// - Returns: What the inner submission gave.
    /// - Throws: The error of the generation.
    static func run(on queue: GenerationQueue, with model: any LanguageModel, log: EventLog<String>) async throws
        -> ReentryOutcome
    {
        let mark = ModelCallMark(sessionID: ULID(), submission: SubmissionTarget(queue: queue, model: IntegrationModels.llm.ref))
        defer { mark.close() }
        return try await ModelCallMark.$current.withValue(mark) {
            let answer = try await Generation.respond(
                to: franceQuestion.prompt, with: model, maximumResponseTokens: shortAnswerTokens)
            let inner = innerSubmission(on: queue, log: log)
            await Waits.untilFirstEnds({ await inner.queued.waitUntilOpen() }, { _ = await inner.task.result })
            // A job that waits behind this open call can never start, thus
            // the cancel takes it out of the queue.
            let waitedInTheQueue = inner.queued.isOpen
            if waitedInTheQueue {
                inner.task.cancel()
            }
            let refusal = await inner.task.result.failure
            return ReentryOutcome(answer: answer, refusal: refusal, waitedInTheQueue: waitedInTheQueue)
        }
    }

    /// Submits a job to `queue` on a new task that inherits the mark of the
    /// caller. The job writes ``ranEvent`` to `log`, and a refusal writes
    /// ``refusedEvent``.
    ///
    /// - Parameters:
    ///   - queue: The queue.
    ///   - log: The log.
    /// - Returns: The task of the submission, and the latch that the queue
    ///   opens when the job waits in the queue.
    private static func innerSubmission(
        on queue: GenerationQueue, log: EventLog<String>
    ) -> (task: Task<Void, any Error>, queued: Latch) {
        let queued = Latch()
        let task = Task {
            do {
                try await queue.submit(onQueued: { queued.open() }) { await log.append(ranEvent) }
            } catch {
                await log.append(refusedEvent)
                throw error
            }
        }
        return (task, queued)
    }
}

extension Result {
    /// The error of a failure, or `nil` for a success.
    fileprivate var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
