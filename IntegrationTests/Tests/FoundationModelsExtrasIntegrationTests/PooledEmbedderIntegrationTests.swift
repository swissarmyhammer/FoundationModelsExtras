import FoundationModels
@testable import FoundationModelsExtras
import InMemoryTracing
import MLXLMCommon
import TelemetryTestSupport
import Testing
import Tracing

/// The most tokens of the long generation that runs while an embed call runs.
/// The model cannot finish the prompt early, thus the generation runs for some
/// seconds, and one embed call takes much less time.
private let longGenerationTokens = 1024

/// A question that the model answers until its token limit.
private let endlessPrompt = "Count upward from 1, one number per line, without stopping."

/// A text that a test embeds when only the shape of the result is important.
private let probeText = "The pool shares one embedding model."

/// Three texts: two that have the same meaning, and one that has an unrelated
/// meaning.
private enum SimilarityTexts {
    /// The text that the other two are compared with.
    static let anchor = "A cat sleeps on the warm windowsill."
    /// A different text with the meaning of ``anchor``.
    static let paraphrase = "A kitten naps in the sun by the window."
    /// A text with a meaning that is not related to ``anchor``.
    static let unrelated = "The central bank raised the interest rate by half a percent."
    /// The three texts, in one list.
    static let all = [anchor, paraphrase, unrelated]
}

/// Three texts of different token lengths. One batch of them pads the two
/// shorter texts to the length of the longest text.
private enum BatchLengthTexts {
    /// The shortest text.
    static let short = "Open the file."
    /// A text of medium length.
    static let medium = "Find the tool that lists the files of a folder."
    /// The longest text.
    static let long = """
        Summarize the open pull requests of the repository, and give the name of \
        the reviewer of each one, with the date of its last change.
        """
    /// The three texts, in one list.
    static let all = [short, medium, long]
}

/// Many short texts and one long text. In one padded tensor, the long text
/// pads each short text to its length. Divided into sub-batches by token
/// count, the long text goes in a sub-batch by itself.
private enum MixedLengthTexts {
    /// The count of short texts before the long text in ``all``. It is not
    /// zero, thus the sort changes the order of the texts.
    static let shortCountBeforeLong = 7

    /// The count of short texts after the long text in ``all``. It is not
    /// zero, thus the long text is in the middle of ``all``.
    static let shortCountAfterLong = 8

    /// The count of short texts.
    static let shortCount = shortCountBeforeLong + shortCountAfterLong

    /// The count of sentences in the long text: more than 1,000 tokens. One
    /// padded tensor of all the texts is then much larger than the
    /// sub-batches of the same texts.
    static let longSentenceCount = 100

    /// The sentence that the long text repeats.
    static let longSentence = "The pool shares one embedding model with each user of the key. "

    /// The long text.
    static let long = String(repeating: longSentence, count: longSentenceCount)

    /// The short texts.
    static let shorts = (1...shortCount).map { "Find the tool number \($0) of the folder." }

    /// The place of the long text in ``all``: after
    /// ``shortCountBeforeLong`` short texts.
    static let longIndex = shortCountBeforeLong

    /// The short texts, with the long text at ``longIndex``.
    static let all = Array(shorts[..<longIndex]) + [long] + Array(shorts[longIndex...])
}

/// The smallest ratio of the tokens of one padded batch of
/// ``MixedLengthTexts/all`` to the padded tokens of the sub-batches of the
/// real call. Only one row of the call has the length of the long text, thus
/// the sub-batches must pad far fewer tokens.
private let minimumPaddingReduction = 4

/// The lowest cosine between the vector of a text in a batch and the vector of
/// the same text alone. The pad tokens of a batch must not change a vector, thus
/// only the rounding of the float math can make the two vectors differ.
private let batchCosineFloor: Float = 0.999

/// The sub-batch count of a call whose texts all go in one sub-batch. The
/// telemetry test needs more sub-batches than this, so that it sees a real
/// division.
private let oneSubBatch = 1

/// The depth of the queue of the embedding model when the first job runs and
/// no call waits.
private let depthOfTheFirstJob = 1

/// The texts that the two users of one embedding model embed.
private let sharedTexts = ["Route this question to the best model.", "Find the tool that reads a file."]

/// The step that the overlap test writes when the embed call returned.
private let embedEnded = "the embed call ended"

/// The step that the overlap test writes when the generation ended.
private let generationEnded = "the generation ended"

/// A user of the shared embedding model.
private enum EmbedderUser {
    /// The router, which embeds the prompts.
    case router
    /// The metadata registry, which embeds the descriptions of the tools.
    case registry
}

/// One embed call of the FIFO test: the user that makes it and its one text.
private struct EmbedCall {
    /// The user that calls `embed(texts:)`.
    let user: EmbedderUser
    /// The text of the call.
    let text: String
}

/// The concurrent embed calls of the FIFO test, in the order in which they go
/// into the queue. The two users take turns.
private let concurrentCalls = [
    EmbedCall(user: .router, text: "Summarize the open pull requests."),
    EmbedCall(user: .registry, text: "A tool that lists the files of a folder."),
    EmbedCall(user: .router, text: "Write a unit test for the parser."),
    EmbedCall(user: .registry, text: "A tool that runs a shell command."),
    EmbedCall(user: .router, text: "Explain the last build failure."),
    EmbedCall(user: .registry, text: "A tool that searches the code for a symbol."),
]

extension RealModelSuites {
    /// `PooledEmbedder` with the real MLX embedding model: real vectors, one
    /// model that two users share, one embed call at a time on the queue of the
    /// model, the residency that the embedder handles keep, and the span tree
    /// of an embed call with real tokens and real sub-batches.
    @Suite("Pooled embedder with a real model")
    struct PooledEmbedderIntegrationTests {
        @Test("a real embed by name gives one vector for each text, and a paraphrase has a higher cosine than an unrelated text")
        func realEmbedByNamePlacesSimilarTextsCloser() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.embedSimilarityTextsByName(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let dimension = try #require(outcome.batch.first).count
            let similar = VectorMath.cosineSimilarity(of: outcome.anchor, to: outcome.paraphrase)
            let unrelated = VectorMath.cosineSimilarity(of: outcome.anchor, to: outcome.unrelated)
            #expect(dimension > 0)
            #expect(outcome.batch.map(\.count) == Array(repeating: dimension, count: SimilarityTexts.all.count))
            #expect([outcome.anchor, outcome.paraphrase, outcome.unrelated].allSatisfy { $0.count == dimension })
            #expect(similar > unrelated, "similar texts: \(similar); unrelated texts: \(unrelated)")
        }

        @Test(
            "each text of a batch of texts of different lengths has the vector of the same text embedded alone",
            arguments: [BatchLengthTexts.all, MixedLengthTexts.all])
        func batchVectorEqualsVectorOfTextAlone(texts: [String]) async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.embedInBatchAndAlone(texts: texts, in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let cosines = zip(outcome.batch, outcome.alone).map { VectorMath.cosineSimilarity(of: $0, to: $1) }
            #expect(outcome.batch.count == texts.count)
            #expect(outcome.alone.count == texts.count)
            #expect(cosines.allSatisfy { $0 >= batchCosineFloor }, "cosines: \(cosines)")
        }

        @Test("a call of short texts and one long text pads far fewer tokens than one padded batch of the same texts")
        func mixedLengthCallPadsFarFewerTokensThanOnePaddedBatch() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let context = try await Self.captureMixedLengthEmbed(in: pool, tokenizerLoader: RecordingTokenizerLoader())
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let embedSpan = try CapturedSpans.onlySpan(named: ExtrasTelemetry.SpanName.embed, in: context.spans)
            let subBatchSpans = CapturedSpans.children(
                named: ExtrasTelemetry.SpanName.embedSubBatch, of: embedSpan, in: context.spans)
            let textCount = try EmbedSpanExpectations.countAttribute(ExtrasTelemetry.AttributeKey.embedTextCount, of: embedSpan)
            let maxTokens = try EmbedSpanExpectations.countAttribute(ExtrasTelemetry.AttributeKey.embedMaxTokens, of: embedSpan)
            let paddedTokens = try subBatchSpans.reduce(0) { total, span in
                total + (try EmbedSpanExpectations.countAttribute(ExtrasTelemetry.AttributeKey.subBatchPaddedTokens, of: span))
            }
            let onePaddedBatch = textCount * maxTokens
            #expect(textCount == MixedLengthTexts.all.count)
            #expect(subBatchSpans.count > oneSubBatch)
            #expect(
                onePaddedBatch >= minimumPaddingReduction * paddedTokens,
                "the sub-batches padded \(paddedTokens) tokens; one padded batch has \(onePaddedBatch) tokens")
        }

        @Test("a router and a registry acquire one embedding key, the model loads one time, and the registry embeds with the router container")
        func twoUsersShareOneLoadOfTheModel() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let routerLoader = RecordingLoader()
            let registryLoader = RecordingLoader()

            let outcome = try await Self.shareOneModel(in: pool, routerLoader: routerLoader, registryLoader: registryLoader)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            #expect(await routerLoader.loadedKeys == [IntegrationModels.embedding])
            #expect(await registryLoader.loadedKeys.isEmpty)
            #expect(outcome.shareOneQueue)
            let dimension = try #require(outcome.routerVectors.first).count
            #expect(dimension > 0)
            #expect(outcome.registryVectors.map(\.count) == Array(repeating: dimension, count: sharedTexts.count))
            #expect(outcome.registryVectors == outcome.routerVectors)
        }

        @Test("concurrent embed calls of two users run one at a time, first in first out, and each gives the vectors of a serial run")
        func concurrentEmbedsRunOneAtATimeInOrder() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let loader = RecordingEmbeddingLoader()

            let outcome = try await Self.embedConcurrently(in: pool, loader: loader)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            // The serial run made the first steps, and the concurrent calls made the rest.
            let steps = await Array(loader.steps.events.dropFirst(EmbedStep.steps(of: concurrentCalls).count))
            #expect(steps == EmbedStep.steps(of: concurrentCalls), "calls: \(steps)")
            #expect(outcome.concurrentVectors == outcome.serialVectors)
        }

        @Test("an embedder handle keeps the real model resident, and the release of the last handle evicts it")
        func embedderHandleKeepsTheModelResident() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.releaseOneOfTwoHandles(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            #expect(outcome.isResidentAfterFirstRelease)
            let dimension = try #require(outcome.releasedHandleVectors.first).count
            #expect(dimension > 0)
            #expect(outcome.releasedHandleVectors.map(\.count) == [dimension])
            #expect(outcome.remainingHandleVectors.map(\.count) == [dimension])
            #expect(!pool.isResident(IntegrationModels.embedding))
        }

        @Test("with the real LLM and the real embedding model resident, an embed call does not wait behind a long generation")
        func embedDoesNotWaitBehindAGeneration() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.embedDuringGeneration(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.llm, in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            #expect(!outcome.shareOneQueue)
            let dimension = try #require(outcome.vectors.first).count
            #expect(dimension > 0)
            #expect(outcome.vectors.map(\.count) == [dimension])
            #expect(outcome.steps == [embedEnded, generationEnded])
        }

        @Test(
            """
            a real embed of texts of mixed length opens one embed span with one tokenize child span and one \
            sub-batch child span for each sub-batch, with the counts of the real tokens and no text
            """)
        func anEmbedCallOpensItsSpanTreeWithTheRealCounts() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let tokenizerLoader = RecordingTokenizerLoader()

            let context = try await Self.captureMixedLengthEmbed(in: pool, tokenizerLoader: tokenizerLoader)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let tokenizer = try #require(await tokenizerLoader.tokenizers.events.first)
            let statistics = EmbedSpanExpectations.statistics(of: MixedLengthTexts.all, tokenizedBy: tokenizer)
            try #require(statistics.subBatchCount > oneSubBatch, "the texts divide into more than one sub-batch")
            let embedSpan = try CapturedSpans.onlySpan(named: ExtrasTelemetry.SpanName.embed, in: context.spans)
            let tokenizeSpans = CapturedSpans.children(
                named: ExtrasTelemetry.SpanName.embedTokenize, of: embedSpan, in: context.spans)
            let subBatchSpans = CapturedSpans.children(
                named: ExtrasTelemetry.SpanName.embedSubBatch, of: embedSpan, in: context.spans)

            #expect(tokenizeSpans.count == CapturedSpans.oneSpanOfEachName)
            EmbedSpanExpectations.expectCallAttributes(of: embedSpan, statistics: statistics)
            try #require(subBatchSpans.count == statistics.subBatchCount)
            for (span, subBatch) in zip(subBatchSpans, statistics.subBatches) {
                EmbedSpanExpectations.expectSubBatchAttributes(of: span, subBatch)
            }
            #expect(!context.logRecords.isEmpty, "the capture holds the log records of the call")
            #expect(!context.metricRecords.isEmpty, "the capture holds the metrics of the call")
        }

        /// Makes an embedder that keeps a new hold of the embedding model.
        private static func makeEmbedder(
            in pool: ModelPool, loader: any PooledModelLoader = MLXModelLoader()
        ) async throws -> PooledEmbedder {
            try PooledEmbedder(hold: try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: loader))
        }

        /// Embeds the similarity texts one at a time and in one batch, through
        /// an embedder made from the name of the embedding model. The first
        /// call loads the model with the loader of `pool`. The embedder goes on
        /// return.
        private static func embedSimilarityTextsByName(in pool: ModelPool) async throws -> SimilarityOutcome {
            let embedder = PooledEmbedder(ref: IntegrationModels.embedding.ref, pool: pool)
            return SimilarityOutcome(
                batch: try await embedder.embed(texts: SimilarityTexts.all),
                anchor: try await vector(of: SimilarityTexts.anchor, with: embedder),
                paraphrase: try await vector(of: SimilarityTexts.paraphrase, with: embedder),
                unrelated: try await vector(of: SimilarityTexts.unrelated, with: embedder))
        }

        /// Embeds `texts` in one batch, and then each text alone, through one
        /// embedder. The embedder goes on return.
        private static func embedInBatchAndAlone(texts: [String], in pool: ModelPool) async throws -> BatchOutcome {
            let embedder = try await makeEmbedder(in: pool)
            return BatchOutcome(
                batch: try await embedder.embed(texts: texts),
                alone: try await embedSerially(texts, with: embedder))
        }

        /// Embeds `text` alone, and gives its one vector.
        private static func vector(of text: String, with embedder: PooledEmbedder) async throws -> [Float] {
            try #require(try await embedder.embed(texts: [text]).first)
        }

        /// Acquires the embedding model first for the router and then for the
        /// registry, each with its own loader, and embeds the shared texts
        /// through the embedder of each. The holds go on return.
        private static func shareOneModel(
            in pool: ModelPool, routerLoader: RecordingLoader, registryLoader: RecordingLoader
        ) async throws -> SharedModelOutcome {
            let routerHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: routerLoader)
            let registryHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: registryLoader)
            let router = try PooledEmbedder(hold: routerHold)
            let registry = try PooledEmbedder(hold: registryHold)
            return SharedModelOutcome(
                shareOneQueue: routerHold.queue === registryHold.queue,
                routerVectors: try await router.embed(texts: sharedTexts),
                registryVectors: try await registry.embed(texts: sharedTexts))
        }

        /// Embeds the text of each concurrent call first in a serial run, and
        /// then in concurrent calls of the two users. A first job holds the
        /// queue until all the concurrent calls wait in it. The holds go on
        /// return.
        private static func embedConcurrently(in pool: ModelPool, loader: RecordingEmbeddingLoader) async throws -> ConcurrentOutcome {
            let routerHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: loader)
            let queue = routerHold.queue
            let users = EmbedderUsers(
                router: try PooledEmbedder(hold: routerHold), registry: try await makeEmbedder(in: pool, loader: loader))
            let serialVectors = try await embedSerially(concurrentCalls.map(\.text), with: users.router)
            let concurrentVectors = try await TelemetryCapture.run(forbidding: []) { context in
                let firstJobRuns = Latch()
                let allCallsWait = Latch()
                let firstJob = Task {
                    try await queue.submit {
                        firstJobRuns.open()
                        await allCallsWait.waitUntilOpen()
                    }
                }
                await Waits.untilFirstEnds({ await firstJobRuns.waitUntilOpen() }, { _ = await firstJob.result })
                let calls = await startInTurns(concurrentCalls, with: users, recordingInto: context)
                allCallsWait.open()
                try await firstJob.value
                var vectors: [[Float]] = []
                for call in calls {
                    vectors.append(try await call.value)
                }
                return vectors
            }
            return ConcurrentOutcome(serialVectors: serialVectors, concurrentVectors: concurrentVectors)
        }

        /// Embeds each text in its own call, one call after the other.
        private static func embedSerially(_ texts: [String], with embedder: PooledEmbedder) async throws -> [[Float]] {
            let (stream, continuation) = AsyncStream.makeStream(of: String.self)
            for text in texts {
                continuation.yield(text)
            }
            continuation.finish()
            return try await stream.reduce(into: []) { vectors, text in
                vectors.append(try await vector(of: text, with: embedder))
            }
        }

        /// Starts `calls` on new tasks, one after the other, while a first job
        /// runs in the queue of the embedding model. Each call starts when the
        /// call before it waits in the queue, thus the calls go into the queue
        /// in the order of `calls`.
        ///
        /// The queue records its depth in `context` in the step that accepts a
        /// call. A call that ends before it waits in the queue also ends its
        /// wait, and the order check of the test then fails.
        ///
        /// - Parameters:
        ///   - calls: The calls, in order.
        ///   - users: The embedder of each user.
        ///   - context: The capture that gets the depth of the queue.
        /// - Returns: The task of each call, in the order of `calls`.
        private static func startInTurns(
            _ calls: [EmbedCall], with users: EmbedderUsers, recordingInto context: TelemetryCapture.Context
        ) async -> [Task<[Float], any Error>] {
            var tasks: [Task<[Float], any Error>] = []
            for (index, call) in calls.enumerated() {
                let task = Task { try await vector(of: call.text, with: users.embedder(for: call.user)) }
                let depth = Double(depthOfTheFirstJob + index + 1)
                await Waits.untilFirstEnds(
                    { await context.wait { QueueDepth.model(IntegrationModels.embedding, in: $0) == depth } },
                    { _ = await task.result })
                tasks.append(task)
            }
            return tasks
        }

        /// Makes two embedder handles, embeds with each, and releases one of
        /// them. The other handle goes on return.
        private static func releaseOneOfTwoHandles(in pool: ModelPool) async throws -> ResidencyOutcome {
            let remainingHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool)
            let remaining = try PooledEmbedder(hold: remainingHold)
            let releasedHandleVectors = try await embedWithShortLivedHandle(in: pool)
            // An eviction job runs in the admission queue. This empty job ends
            // after each eviction job that is in the admission queue now.
            try await pool.admit { _ in }
            return ResidencyOutcome(
                isResidentAfterFirstRelease: pool.isResident(IntegrationModels.embedding),
                releasedHandleVectors: releasedHandleVectors,
                remainingHandleVectors: try await remaining.embed(texts: [probeText]))
        }

        /// Embeds with a new embedder handle. The handle goes on return.
        private static func embedWithShortLivedHandle(in pool: ModelPool) async throws -> [[Float]] {
            try await makeEmbedder(in: pool).embed(texts: [probeText])
        }

        /// Starts a long generation on the queue of the LLM, and embeds while
        /// it runs. The test writes the end of the embed call and the end of
        /// the generation into one log. The holds go on return.
        private static func embedDuringGeneration(in pool: ModelPool) async throws -> GenerationOverlapOutcome {
            let llmHold = try await IntegrationModels.acquire(key: IntegrationModels.llm, in: pool)
            let model = try Generation.languageModel(of: llmHold)
            let embeddingHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool)
            let embedder = try PooledEmbedder(hold: embeddingHold)
            let steps = EventLog<String>()
            let generationRuns = Latch()
            let generation = Task {
                try await llmHold.queue.submit {
                    generationRuns.open()
                    _ = try await Generation.respond(to: endlessPrompt, with: model, maximumResponseTokens: longGenerationTokens)
                    await steps.append(generationEnded)
                }
            }
            // A generation that ends before it opens the latch also ends the
            // wait, and the order check of the test then fails.
            await Waits.untilFirstEnds({ await generationRuns.waitUntilOpen() }, { _ = await generation.result })
            let vectors = try await embedder.embed(texts: [probeText])
            await steps.append(embedEnded)
            try await generation.value
            return GenerationOverlapOutcome(
                shareOneQueue: llmHold.queue === embeddingHold.queue, vectors: vectors, steps: await steps.events)
        }

        /// Makes an embedder whose model loads with `tokenizerLoader`, and
        /// embeds ``MixedLengthTexts/all`` in one call in a telemetry capture.
        /// The capture forbids each of the texts in each span, log record and
        /// metric. The embedder goes on return.
        ///
        /// - Parameters:
        ///   - pool: The pool of the test.
        ///   - tokenizerLoader: The tokenizer loader of the load of the model.
        /// - Returns: The capture of the embed call.
        /// - Throws: The error of the load or of the embed call.
        private static func captureMixedLengthEmbed(
            in pool: ModelPool, tokenizerLoader: RecordingTokenizerLoader
        ) async throws -> TelemetryCapture.Context {
            let embedder = try await makeEmbedder(in: pool, loader: MLXModelLoader(tokenizerLoader: tokenizerLoader))
            return try await TelemetryCapture.run(forbidding: MixedLengthTexts.all) { context in
                _ = try await embedder.embed(texts: MixedLengthTexts.all)
                return context
            }
        }
    }
}

/// The checks of the spans of one real embed call.
///
/// The unit target has the same checks for a fake model, but a test of this
/// package cannot see the unit target. Thus these checks compare the span
/// attributes with one table of expected values.
private enum EmbedSpanExpectations {
    /// Gives the counts of one embed call of `texts`, from the real token rows.
    ///
    /// `MLXEmbedding` tokenizes each text with its special tokens, and divides
    /// the rows with the default token budget, thus this does the same.
    ///
    /// - Parameters:
    ///   - texts: The texts of the call.
    ///   - tokenizer: The tokenizer of the loaded model.
    /// - Returns: The counts that the spans of the call must carry.
    static func statistics(
        of texts: [String], tokenizedBy tokenizer: any MLXLMCommon.Tokenizer
    ) -> EmbeddingBatchStatistics {
        let rows = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
        return EmbeddingBatchStatistics(of: EmbeddingBatchDivision(rows: rows))
    }

    /// Expects that `span` carries the ref of the embedding model and the
    /// counts of the call.
    ///
    /// - Parameters:
    ///   - span: The embed span.
    ///   - statistics: The counts of the call.
    static func expectCallAttributes(of span: FinishedInMemorySpan, statistics: EmbeddingBatchStatistics) {
        expect(
            [
                (ExtrasTelemetry.AttributeKey.modelRef, .string(IntegrationModels.embedding.ref.stringValue)),
                (ExtrasTelemetry.AttributeKey.embedTextCount, count(statistics.textCount)),
                (ExtrasTelemetry.AttributeKey.embedTokenCount, count(statistics.tokenCount)),
                (ExtrasTelemetry.AttributeKey.embedMaxTokens, count(statistics.maxTokens)),
                (ExtrasTelemetry.AttributeKey.embedSubBatchCount, count(statistics.subBatchCount)),
                (ExtrasTelemetry.AttributeKey.embedOverBudgetRows, count(statistics.overBudgetRows)),
            ], on: span)
    }

    /// Expects that `span` carries the counts of `subBatch`.
    ///
    /// - Parameters:
    ///   - span: A sub-batch span.
    ///   - subBatch: The counts of the sub-batch.
    static func expectSubBatchAttributes(of span: FinishedInMemorySpan, _ subBatch: EmbeddingBatchStatistics.SubBatch) {
        expect(
            [
                (ExtrasTelemetry.AttributeKey.subBatchRows, count(subBatch.rows)),
                (ExtrasTelemetry.AttributeKey.subBatchLongestRow, count(subBatch.longestRow)),
                (ExtrasTelemetry.AttributeKey.subBatchPaddedTokens, count(subBatch.paddedTokens)),
                (ExtrasTelemetry.AttributeKey.subBatchPadRatio, .double(subBatch.padRatio)),
            ], on: span)
    }

    /// Gives the count that `span` carries as the attribute `key`.
    ///
    /// - Parameters:
    ///   - key: The key of a count attribute.
    ///   - span: The span.
    /// - Returns: The count.
    /// - Throws: A failed expectation when the span has no count with `key`.
    static func countAttribute(_ key: String, of span: FinishedInMemorySpan) throws -> Int {
        Int(try #require(span.attributes.get(key)?.integerValue, "the span \(span.operationName) has no count \(key)"))
    }

    /// Expects that `span` carries each attribute of `attributes`.
    ///
    /// - Parameters:
    ///   - attributes: The key and the expected value of each attribute.
    ///   - span: The span.
    private static func expect(_ attributes: [(key: String, value: SpanAttribute)], on span: FinishedInMemorySpan) {
        for attribute in attributes {
            #expect(
                span.attributes.get(attribute.key) == attribute.value,
                "the attribute \(attribute.key) of \(span.operationName)")
        }
    }

    /// Gives the span attribute of a count, as the embed telemetry records it.
    ///
    /// - Parameter value: The count.
    /// - Returns: The count as a 64-bit integer attribute.
    private static func count(_ value: Int) -> SpanAttribute {
        .int64(Int64(value))
    }
}

/// The math of the similarity check.
private enum VectorMath {
    /// The cosine of the angle between two vectors of one length.
    static func cosineSimilarity(of first: [Float], to second: [Float]) -> Float {
        zip(first, second).lazy.map(*).reduce(0, +) / (length(of: first) * length(of: second))
    }

    /// The Euclidean length of `vector`.
    private static func length(of vector: [Float]) -> Float {
        vector.lazy.map { $0 * $0 }.reduce(0, +).squareRoot()
    }
}

/// The embedder of each user in the FIFO test.
private struct EmbedderUsers: Sendable {
    /// The embedder of the router.
    let router: PooledEmbedder
    /// The embedder of the registry.
    let registry: PooledEmbedder

    /// The embedder of `user`.
    func embedder(for user: EmbedderUser) -> PooledEmbedder {
        switch user {
        case .router: router
        case .registry: registry
        }
    }
}

/// The vectors of the similarity test.
private struct SimilarityOutcome {
    /// The vectors of one call with all the similarity texts.
    let batch: [[Float]]
    /// The vector of ``SimilarityTexts/anchor``, embedded alone.
    let anchor: [Float]
    /// The vector of ``SimilarityTexts/paraphrase``, embedded alone.
    let paraphrase: [Float]
    /// The vector of ``SimilarityTexts/unrelated``, embedded alone.
    let unrelated: [Float]
}

/// The vectors of the batch test.
private struct BatchOutcome {
    /// The vector of each text, from one call with all the texts.
    let batch: [[Float]]
    /// The vector of each text, from one call for each text.
    let alone: [[Float]]
}

/// What the two users of one embedding model observed.
private struct SharedModelOutcome {
    /// Whether the holds of the two users share one queue, thus one pool entry.
    let shareOneQueue: Bool
    /// The vectors of the shared texts through the embedder of the router.
    let routerVectors: [[Float]]
    /// The vectors of the shared texts through the embedder of the registry.
    let registryVectors: [[Float]]
}

/// The vectors of the FIFO test.
private struct ConcurrentOutcome {
    /// The vector of each call text, from one call after the other.
    let serialVectors: [[Float]]
    /// The vector of each concurrent call, in the order of the calls.
    let concurrentVectors: [[Float]]
}

/// What the residency test observed.
private struct ResidencyOutcome {
    /// Whether the model was resident after the release of the first handle.
    let isResidentAfterFirstRelease: Bool
    /// The vectors of the handle that the test released first.
    let releasedHandleVectors: [[Float]]
    /// The vectors of the remaining handle, after the release of the first handle.
    let remainingHandleVectors: [[Float]]
}

/// What the test of an embed call during a generation observed.
private struct GenerationOverlapOutcome {
    /// Whether the LLM and the embedding model share one queue.
    let shareOneQueue: Bool
    /// The vectors of the embed call.
    let vectors: [[Float]]
    /// The end of the embed call and the end of the generation, in order.
    let steps: [String]
}

/// One step of an embed call that a ``RecordingEmbedding`` ran.
private enum EmbedStep: Equatable, Sendable {
    /// The call with these texts started.
    case started([String])
    /// The call with these texts ended.
    case ended([String])

    /// The steps of `calls` when they run one at a time, in order: the start
    /// and the end of each call with its one text.
    ///
    /// - Parameter calls: The calls, in order.
    /// - Returns: The steps.
    static func steps(of calls: [EmbedCall]) -> [EmbedStep] {
        calls.flatMap { [.started([$0.text]), .ended([$0.text])] }
    }
}

/// A ``PooledEmbedding`` that records the start and the end of each call of
/// the embedding it wraps.
private struct RecordingEmbedding: PooledEmbedding {
    /// The embedding that does the real work.
    let embedding: any PooledEmbedding
    /// The steps of the calls, in order.
    let steps: EventLog<EmbedStep>

    /// Embeds `texts` with the wrapped embedding, and records the call.
    func embed(texts: [String]) async throws -> [[Float]] {
        await steps.append(.started(texts))
        let vectors = try await embedding.embed(texts: texts)
        await steps.append(.ended(texts))
        return vectors
    }
}

/// A loader that loads the MLX embedding model with `MLXModelLoader`, and
/// gives it wrapped in a ``RecordingEmbedding``. The first loader of a key gives
/// the container of all holds, thus each user of the key records its calls here.
private struct RecordingEmbeddingLoader: PooledModelLoader {
    /// The steps of the embed calls of each user of the loaded model.
    let steps = EventLog<EmbedStep>()

    /// The loader that does the real work.
    private let loader = MLXModelLoader()

    /// Loads the model of `key`, and wraps it.
    ///
    /// - Parameter key: An embedding model.
    /// - Returns: A ``RecordingEmbedding``.
    /// - Throws: The error of the load, or a failed expectation when the
    ///   container is not a ``PooledEmbedding``.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        let embedding = try #require(try await loader.load(key) as? any PooledEmbedding)
        return RecordingEmbedding(embedding: embedding, steps: steps)
    }

    /// Evicts the container with `MLXModelLoader`.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await loader.evict(container)
    }
}
