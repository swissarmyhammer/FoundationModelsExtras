import FoundationModels
@testable import FoundationModelsExtras
import InMemoryTracing
import MLXLMCommon
import TelemetryTestSupport
import Testing
import Tracing

/// The most tokens of the generation that runs while an embed call runs. The
/// generation waits at a latch after its first snapshot until the embed call
/// returned, thus this count changes only the time of the test, not its
/// result.
private let longGenerationTokens = 256

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

/// The step that the overlap test writes when the embed call returned.
private let embedEnded = "the embed call ended"

/// The step that the overlap test writes when the generation ended.
private let generationEnded = "the generation ended"

/// The tokenizer loader of the shared load of the embedding model. The span
/// test tokenizes its texts with the tokenizer that this loader gave.
private let sharedTokenizerLoader = RecordingTokenizerLoader()

extension RealModelSuites {
    /// `PooledEmbedder` with the real MLX embedding model: real vectors, an
    /// embed call that does not wait behind a generation of the LLM, and the
    /// span tree of an embed call with real tokens and real sub-batches.
    ///
    /// The unit tests of `PooledEmbedder` prove the share of one model by two
    /// users, the order of concurrent calls and the residency that the
    /// handles keep. These need no real model.
    @Suite(
        "Pooled embedder with a real model",
        .sharedLoads(
            SharedModel(IntegrationModels.embedding, loader: MLXModelLoader(tokenizerLoader: sharedTokenizerLoader)),
            SharedModel(IntegrationModels.llm)))
    struct PooledEmbedderIntegrationTests {
        @Test("a real embed by name gives one vector for each text, and a paraphrase has a higher cosine than an unrelated text")
        func realEmbedByNamePlacesSimilarTextsCloser() async throws {
            let outcome = try await Self.embedSimilarityTextsByName(in: try SharedModels.required().pool)

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
            let outcome = try await Self.embedInBatchAndAlone(texts: texts, with: try Self.sharedEmbedder())

            let cosines = zip(outcome.batch, outcome.alone).map { VectorMath.cosineSimilarity(of: $0, to: $1) }
            #expect(outcome.batch.count == texts.count)
            #expect(outcome.alone.count == texts.count)
            #expect(cosines.allSatisfy { $0 >= batchCosineFloor }, "cosines: \(cosines)")
        }

        @Test("with the real LLM and the real embedding model resident, an embed call does not wait behind a generation")
        func embedDoesNotWaitBehindAGeneration() async throws {
            let outcome = try await Self.embedDuringGeneration(with: try SharedModels.required())

            let dimension = try #require(outcome.vectors.first).count
            #expect(dimension > 0)
            #expect(outcome.vectors.map(\.count) == [dimension])
            #expect(outcome.steps == [embedEnded, generationEnded])
        }

        @Test(
            """
            a real embed of texts of mixed length opens one embed span with one tokenize child span and one \
            sub-batch child span for each sub-batch, with the counts of the real tokens and no text, and the \
            sub-batches pad far fewer tokens than one padded batch of the same texts
            """)
        func anEmbedCallOpensItsSpanTreeWithTheRealCounts() async throws {
            let context = try await Self.captureMixedLengthEmbed(with: try Self.sharedEmbedder())

            let tokenizer = try #require(await sharedTokenizerLoader.tokenizers.events.first)
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
            try EmbedSpanExpectations.expectFarFewerPaddedTokens(on: embedSpan, subBatches: subBatchSpans)
            #expect(!context.logRecords.isEmpty, "the capture holds the log records of the call")
            #expect(!context.metricRecords.isEmpty, "the capture holds the metrics of the call")
        }

        /// An embedder that keeps a new hold of the shared embedding model.
        ///
        /// - Returns: The embedder.
        /// - Throws: A failed expectation when the suite has no shared
        ///   embedding model, or when its container does not embed.
        private static func sharedEmbedder() throws -> PooledEmbedder {
            try PooledEmbedder(hold: try SharedModels.required().hold(of: IntegrationModels.embedding))
        }

        /// Embeds the similarity texts one at a time and in one batch, through
        /// an embedder made from the name of the embedding model. The embedder
        /// finds the shared model resident in `pool`. The embedder goes on
        /// return.
        private static func embedSimilarityTextsByName(in pool: ModelPool) async throws -> SimilarityOutcome {
            let embedder = PooledEmbedder(ref: IntegrationModels.embedding.ref, pool: pool)
            return SimilarityOutcome(
                batch: try await embedder.embed(texts: SimilarityTexts.all),
                anchor: try await vector(of: SimilarityTexts.anchor, with: embedder),
                paraphrase: try await vector(of: SimilarityTexts.paraphrase, with: embedder),
                unrelated: try await vector(of: SimilarityTexts.unrelated, with: embedder))
        }

        /// Embeds `texts` in one batch, and then each text alone, through
        /// `embedder`.
        private static func embedInBatchAndAlone(texts: [String], with embedder: PooledEmbedder) async throws -> BatchOutcome {
            BatchOutcome(
                batch: try await embedder.embed(texts: texts),
                alone: try await embedSerially(texts, with: embedder))
        }

        /// Embeds `text` alone, and gives its one vector.
        private static func vector(of text: String, with embedder: PooledEmbedder) async throws -> [Float] {
            try #require(try await embedder.embed(texts: [text]).first)
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

        /// Starts a generation on the shared LLM, holds it after its first
        /// snapshot, and embeds while it is held. The generation continues
        /// when the embed call returned. The LLM and the embedding model share
        /// no lock, thus the embed call does not wait for the generation. The
        /// test writes the end of the embed call and the end of the generation
        /// into one log. The generation ends before this function returns,
        /// also when the embed call throws.
        private static func embedDuringGeneration(with shared: SharedModels) async throws -> GenerationOverlapOutcome {
            let llmHold = try shared.hold(of: IntegrationModels.llm)
            let model = try Generation.languageModel(of: llmHold)
            let embedder = try PooledEmbedder(hold: try shared.hold(of: IntegrationModels.embedding))
            let steps = EventLog<String>()
            let generationIsHeld = Latch()
            let generationMayContinue = Latch()
            let ends = try await TelemetryCapture.run(forbidding: []) { _ in
                let generation = Task {
                    _ = try await Generation.stream(
                        endlessPrompt, with: model, maximumResponseTokens: longGenerationTokens,
                        into: EventLog<String>()
                    ) {
                        generationIsHeld.open()
                        await generationMayContinue.waitUntilOpen()
                    }
                    await steps.append(generationEnded)
                }
                // A generation that ends before its first snapshot also ends
                // the wait, and the order check of the test then fails.
                await Waits.untilFirstEnds({ await generationIsHeld.waitUntilOpen() }, { _ = await generation.result })
                let embedding = Task {
                    let vectors = try await embedder.embed(texts: [probeText])
                    await steps.append(embedEnded)
                    return vectors
                }
                _ = await embedding.result
                generationMayContinue.open()
                return (generation: await generation.result, embedding: await embedding.result)
            }
            try ends.generation.get()
            return GenerationOverlapOutcome(vectors: try ends.embedding.get(), steps: await steps.events)
        }

        /// Embeds ``MixedLengthTexts/all`` in one call through `embedder`, in a
        /// telemetry capture. The capture forbids each of the texts in each
        /// span, log record and metric.
        ///
        /// - Parameter embedder: An embedder of the shared embedding model.
        /// - Returns: The capture of the embed call.
        /// - Throws: The error of the embed call.
        private static func captureMixedLengthEmbed(with embedder: PooledEmbedder) async throws -> TelemetryCapture.Context {
            try await TelemetryCapture.run(forbidding: MixedLengthTexts.all) { context in
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

    /// Expects that the sub-batches of the call of ``MixedLengthTexts/all``
    /// padded far fewer tokens than one padded batch of its texts.
    ///
    /// - Parameters:
    ///   - embedSpan: The embed span of the call.
    ///   - subBatches: The sub-batch spans of the call.
    /// - Throws: A failed expectation when a span has no count that the check
    ///   reads.
    static func expectFarFewerPaddedTokens(on embedSpan: FinishedInMemorySpan, subBatches: [FinishedInMemorySpan]) throws {
        let textCount = try countAttribute(ExtrasTelemetry.AttributeKey.embedTextCount, of: embedSpan)
        let maxTokens = try countAttribute(ExtrasTelemetry.AttributeKey.embedMaxTokens, of: embedSpan)
        let paddedTokens = try subBatches.reduce(0) { total, span in
            total + (try countAttribute(ExtrasTelemetry.AttributeKey.subBatchPaddedTokens, of: span))
        }
        let onePaddedBatch = textCount * maxTokens
        #expect(textCount == MixedLengthTexts.all.count)
        #expect(
            onePaddedBatch >= minimumPaddingReduction * paddedTokens,
            "the sub-batches padded \(paddedTokens) tokens; one padded batch has \(onePaddedBatch) tokens")
    }

    /// Gives the count that `span` carries as the attribute `key`.
    ///
    /// - Parameters:
    ///   - key: The key of a count attribute.
    ///   - span: The span.
    /// - Returns: The count.
    /// - Throws: A failed expectation when the span has no count with `key`.
    private static func countAttribute(_ key: String, of span: FinishedInMemorySpan) throws -> Int {
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

/// What the test of an embed call during a generation observed.
private struct GenerationOverlapOutcome {
    /// The vectors of the embed call.
    let vectors: [[Float]]
    /// The end of the embed call and the end of the generation, in order.
    let steps: [String]
}
