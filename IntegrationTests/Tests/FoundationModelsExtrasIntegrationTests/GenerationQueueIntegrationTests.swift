import FoundationModels
import FoundationModelsExtras
import Testing

/// The most tokens of a short answer: a capital city in one sentence.
private let shortAnswerTokens = 32

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

/// A question that the model answers until its token limit.
private let endlessPrompt = "Count upward from 1, one number per line, without stopping."

/// The short question of the job after the cancel, and the city that its
/// answer names.
private enum FranceQuestion {
    /// The question.
    static let prompt = "What is the capital city of France?"
    /// The city that a real answer contains.
    static let city = "Paris"
}

extension RealModelSuites {
    /// The `GenerationQueue` of a hold of the real LLM: the cancel of the
    /// running generation stops the decode on the GPU.
    ///
    /// The unit tests of the queue prove the order of the jobs, the cancel of
    /// a waiting job and the refusal of a job that could never start. These
    /// need no real model.
    @Suite("Generation queue with a real model", .sharedLoads(SharedModel(IntegrationModels.llm)))
    struct GenerationQueueIntegrationTests {
        @Test("a cancel of the running real generation stops it well before its token limit, and the next job then runs")
        func cancelledRunningGenerationStopsEarly() async throws {
            let hold = try SharedModels.required().hold(of: IntegrationModels.llm)
            let model = try Generation.languageModel(of: hold)
            let queue = hold.queue
            let snapshots = EventLog<String>()

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
            let generatedText = await snapshots.events.last ?? ""
            let nextAnswer = try await queue.submit {
                try await Generation.respond(
                    to: FranceQuestion.prompt, with: model, maximumResponseTokens: shortAnswerTokens)
            }

            #expect(snapshotsAtCancel >= snapshotsBeforeCancel)
            #expect(throws: CancellationError.self) { try cancelled.get() }
            #expect(
                generatedText.count < cancelledGenerationTokens / farBelowTheLimitDivisor,
                "the cancelled generation gave \(generatedText.count) characters")
            #expect(nextAnswer.contains(FranceQuestion.city), "answer: \(nextAnswer)")
        }
    }
}
