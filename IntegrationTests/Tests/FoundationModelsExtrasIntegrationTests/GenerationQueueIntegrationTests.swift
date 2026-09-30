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

/// The seconds of ``decodeTimeBeforeCancel``.
private let decodeSecondsBeforeCancel = 2

/// How long the cancelled generation runs before the cancel: the prefill is
/// done, and the decode is on the GPU.
private let decodeTimeBeforeCancel = Duration.seconds(decodeSecondsBeforeCancel)

/// The seconds of ``cancelledStopLimit``.
private let cancelledStopLimitSeconds = 5

/// The longest time from the cancel of the running generation to its end. The
/// full generation takes much longer, thus a stop in this time is a stop well
/// before the token limit. On 2026-09-27, on an Apple silicon Mac, the stop
/// took 6 ms.
private let cancelledStopLimit = Duration.seconds(cancelledStopLimitSeconds)

/// The longest time that the queue may take to refuse a job from inside an
/// open model call. The refusal is a check, not a wait.
private let refusalLimit = Duration.seconds(1)

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

extension RealModelSuites {
    /// The `GenerationQueue` of a hold of the real LLM: one generation at a
    /// time on the GPU, the cancel of a job, and the refusal of a job that
    /// could never start.
    @Suite("Generation queue with a real model", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct GenerationQueueIntegrationTests {
        @Test("concurrent generations on one queue run one at a time, first in first out, and each gives a real answer")
        func concurrentGenerationsRunOneAtATimeInOrder() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let records = try await Self.withLLM(in: pool) { queue, model in
                async let paris = Self.submit(turn: 0, to: queue) {
                    try await JobRecord.run(prompt: longParisPrompt, with: model, maximumResponseTokens: longAnswerTokens)
                }
                async let tokyo = Self.submit(turn: 1, to: queue) {
                    try await JobRecord.run(prompt: "What is the capital city of Japan?", with: model, maximumResponseTokens: shortAnswerTokens)
                }
                async let rome = Self.submit(turn: 2, to: queue) {
                    try await JobRecord.run(prompt: "What is the capital city of Italy?", with: model, maximumResponseTokens: shortAnswerTokens)
                }
                return try await [paris, tokyo, rome]
            }

            #expect(zip(records, ["Paris", "Tokyo", "Rome"]).allSatisfy { $0.answer.contains($1) }, "answers: \(records.map(\.answer))")
            #expect(zip(records, records.dropFirst()).allSatisfy { $1.start >= $0.end }, "jobs: \(records)")
        }

        @Test("a cancelled job that waits in the queue never starts, and the running job still gives its answer")
        func cancelledWaitingJobNeverStarts() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let starts = EventLog<String>()

            let outcome = try await Self.withLLM(in: pool) { queue, model in
                async let paris = Self.submit(turn: 0, to: queue) {
                    try await Generation.respond(to: longParisPrompt, with: model, maximumResponseTokens: longAnswerTokens)
                }
                let waiting = Task {
                    try await Self.submit(turn: 1, to: queue) { await starts.append("the cancelled job") }
                }
                try await Waiting.until { await queue.waitingCount == 1 }
                waiting.cancel()
                let waitingCountAfterCancel = await queue.waitingCount
                let answer = try await paris
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

            let outcome = try await Self.withLLM(in: pool) { queue, model in
                let running = Task {
                    try await queue.submit {
                        try await Generation.respond(to: endlessPrompt, with: model, maximumResponseTokens: cancelledGenerationTokens)
                    }
                }
                try await Waiting.until { await queue.isRunning }
                try await Task.sleep(for: decodeTimeBeforeCancel)
                let cancelTime = ContinuousClock.now
                running.cancel()
                let cancelled = await running.result
                let stopDelay = ContinuousClock.now - cancelTime
                let next = try await queue.submit {
                    try await Generation.respond(to: franceQuestion.prompt, with: model, maximumResponseTokens: shortAnswerTokens)
                }
                return RunningCancelOutcome(cancelled: cancelled, stopDelay: stopDelay, nextAnswer: next)
            }

            #expect(throws: CancellationError.self) { try outcome.cancelled.get() }
            #expect(outcome.stopDelay < cancelledStopLimit, "the cancelled generation stopped \(outcome.stopDelay) after the cancel")
            #expect(outcome.nextAnswer.contains(franceQuestion.city), "answer: \(outcome.nextAnswer)")
        }

        @Test("a job that submits to its own queue from inside an open model call gets waitInsideOpenSubmission at once")
        func submissionInsideAnOpenModelCallIsRefused() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.withLLM(in: pool) { queue, model in
                try await queue.submit {
                    try await ReentryOutcome.run(on: queue, with: model)
                }
            }

            #expect(
                outcome.refusal as? GenerationQueueError == .waitInsideOpenSubmission(model: IntegrationModels.llm.ref),
                "refusal: \(String(describing: outcome.refusal))")
            #expect(outcome.refusalDelay < refusalLimit)
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

        /// Submits `body` to `queue` as the job at place `turn` of the queue.
        ///
        /// Turn 0 submits at once. A later turn waits until the job before it
        /// is in the queue behind the running job, thus the jobs of concurrent
        /// tasks go into the queue in the order of their turns.
        private static func submit<T: Sendable>(
            turn: Int, to queue: GenerationQueue, _ body: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            try await Waiting.until { await isTurn(turn: turn, of: queue) }
            return try await queue.submit(body)
        }

        /// Whether the job at place `turn` may go into `queue` now: turn 0 at
        /// once, and a later turn when a job runs and `turn - 1` jobs wait.
        private static func isTurn(turn: Int, of queue: GenerationQueue) async -> Bool {
            guard turn > 0 else { return true }
            let isRunning = await queue.isRunning
            let waitingCount = await queue.waitingCount
            return isRunning && waitingCount == turn - 1
        }
    }
}

/// The answer of one generation job, and the times when the job ran.
private struct JobRecord: Sendable, CustomStringConvertible {
    /// The text of the answer.
    let answer: String
    /// The time when the job started.
    let start: ContinuousClock.Instant
    /// The time when the job ended.
    let end: ContinuousClock.Instant

    /// The start and the end, for a failure message.
    var description: String { "JobRecord(start: \(start), end: \(end))" }

    /// Runs one generation, and records when it ran.
    static func run(prompt: String, with model: any LanguageModel, maximumResponseTokens: Int) async throws -> JobRecord {
        let start = ContinuousClock.now
        let answer = try await Generation.respond(to: prompt, with: model, maximumResponseTokens: maximumResponseTokens)
        return JobRecord(answer: answer, start: start, end: .now)
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
    /// The time from the cancel to the end of the cancelled generation.
    let stopDelay: Duration
    /// The answer of the job after the cancelled one.
    let nextAnswer: String
}

/// What a job that submits to its own queue inside an open model call observed.
private struct ReentryOutcome: Sendable {
    /// The real answer of the model call.
    let answer: String
    /// The error of the inner submission, or `nil` when the queue accepted it.
    let refusal: (any Error)?
    /// The time that the inner submission took.
    let refusalDelay: Duration

    /// Opens a model call on `queue`, gets a real answer in it, and then
    /// submits a job to `queue` from inside the open call. Run this inside a
    /// job of `queue`.
    static func run(on queue: GenerationQueue, with model: any LanguageModel) async throws -> ReentryOutcome {
        let mark = ModelCallMark(sessionID: ULID(), submission: SubmissionTarget(queue: queue, model: IntegrationModels.llm.ref))
        defer { mark.close() }
        return try await ModelCallMark.$current.withValue(mark) {
            let answer = try await Generation.respond(
                to: franceQuestion.prompt, with: model, maximumResponseTokens: shortAnswerTokens)
            let submitTime = ContinuousClock.now
            let refusal = await innerSubmissionError(on: queue)
            return ReentryOutcome(answer: answer, refusal: refusal, refusalDelay: ContinuousClock.now - submitTime)
        }
    }

    /// Submits an empty job to `queue`, and gives its error.
    private static func innerSubmissionError(on queue: GenerationQueue) async -> (any Error)? {
        do {
            try await queue.submit {}
            return nil
        } catch {
            return error
        }
    }
}
