@testable import FoundationModelsExtras
import MetricsTestKit
import TelemetryTestSupport
import Testing

/// The telemetry of one embed call: one embed span with the counts of the
/// call, one tokenize child span, one sub-batch child span for each
/// sub-batch, and the duration timer, the token counter and the padded-tokens
/// recorder of the model.
///
/// Each test runs ``EmbedTelemetry/traceEmbed(of:texts:tokenBudget:tokenize:vectors:)``
/// through a ``TracedFakeEmbedding``, thus no test needs a model. The import
/// is `@testable`, so a test can call the internal helper.
@Suite("Embed telemetry: a span for each embed call and each sub-batch, with token and padding counts")
struct EmbedTelemetryTests {
    /// The model of each call.
    private static let ref: ModelRef = "org/embedder"

    /// A token budget that divides ``texts`` into more than one sub-batch:
    /// two rows of the short texts of six characters.
    private static let smallBudget = 12

    /// The texts of each call. The fake tokenizer gives one token for each
    /// character, thus the long text is longer than ``smallBudget``, and the
    /// other texts are not. Each text holds `q` and `z`, which no hex trace
    /// id or span id holds, thus a text matches no place of the capture by
    /// chance.
    private static let texts = ["qz-a-much-longer-text", "qz-one", "qz-three", "qz-two"]

    /// The sub-batches of ``texts`` in ``smallBudget``: the two texts of six
    /// characters, the text of eight characters, and the long text.
    private static let subBatchesOfTheTexts = 3

    /// The count of spans of one name that one call opens.
    private static let oneSpan = 1

    /// The fake embedding of each call, with ``smallBudget``.
    private static let embedding = TracedFakeEmbedding(ref: ref, tokenBudget: smallBudget)

    /// The fake embedding of each failed call, with ``smallBudget``. Each
    /// model run throws ``FakeModelRunError``, thus the first sub-batch fails.
    private static let failingEmbedding = TracedFakeEmbedding(ref: ref, tokenBudget: smallBudget, modelRunFails: true)

    /// Runs one embed call of ``texts`` in a new capture.
    ///
    /// - Returns: The capture, and the vectors of the call.
    /// - Throws: The error of the call.
    private static func captureOneCall() async throws -> (context: TelemetryCapture.Context, vectors: [[Float]]) {
        try await TelemetryCapture.run(forbidding: texts) { context in
            (context, try await embedding.embed(texts: texts))
        }
    }

    /// Runs one embed call of ``texts`` whose first model run fails, in a new
    /// capture, and expects that the call throws ``FakeModelRunError``.
    ///
    /// - Returns: The capture.
    /// - Throws: The error of the capture.
    private static func captureOneFailedCall() async throws -> TelemetryCapture.Context {
        try await TelemetryCapture.run(forbidding: texts) { context in
            await #expect(throws: FakeModelRunError.self) {
                try await failingEmbedding.embed(texts: texts)
            }
            return context
        }
    }

    @Test("an embed call opens one embed span with the six counts, and one tokenize child span")
    func anEmbedCallOpensOneEmbedSpanAndOneTokenizeSpan() async throws {
        let (context, _) = try await Self.captureOneCall()

        let embedSpans = ModelLoadTelemetryExpectations.spans(named: ExtrasTelemetry.SpanName.embed, in: context.spans)
        let embedSpan = try #require(embedSpans.first)
        let tokenizeSpans = EmbedTelemetryExpectations.children(
            named: ExtrasTelemetry.SpanName.embedTokenize, of: embedSpan, in: context.spans)

        #expect(embedSpans.count == Self.oneSpan)
        #expect(tokenizeSpans.count == Self.oneSpan)
        EmbedTelemetryExpectations.expectCallAttributes(
            of: embedSpan, ref: Self.ref,
            statistics: EmbeddingBatchStatistics(of: Self.embedding.division(of: Self.texts)))
    }

    @Test("each sub-batch opens one sub-batch child span with its rows, longest row, padded tokens and pad ratio")
    func eachSubBatchOpensOneSubBatchSpan() async throws {
        let (context, _) = try await Self.captureOneCall()

        let embedSpan = try #require(
            ModelLoadTelemetryExpectations.spans(named: ExtrasTelemetry.SpanName.embed, in: context.spans).first)
        let subBatchSpans = EmbedTelemetryExpectations.children(
            named: ExtrasTelemetry.SpanName.embedSubBatch, of: embedSpan, in: context.spans)
        let statistics = EmbeddingBatchStatistics(of: Self.embedding.division(of: Self.texts))

        try #require(subBatchSpans.count == Self.subBatchesOfTheTexts)
        for (span, subBatch) in zip(subBatchSpans, statistics.subBatches) {
            EmbedTelemetryExpectations.expectSubBatchAttributes(of: span, subBatch)
        }
    }

    @Test("an embed call records one duration, adds its token count, and records the padded tokens of each sub-batch")
    func anEmbedCallRecordsItsMetrics() async throws {
        let (context, _) = try await Self.captureOneCall()

        let statistics = EmbeddingBatchStatistics(of: Self.embedding.division(of: Self.texts))
        let metrics = context.metricsFactory

        QueueMetricExpectations.expectDurations(
            try EmbedTelemetryExpectations.durations(in: metrics, ref: Self.ref, outcome: .succeeded),
            count: Self.oneSpan)
        #expect(try EmbedTelemetryExpectations.tokenCounts(in: metrics, ref: Self.ref) == [Int64(statistics.tokenCount)])
        #expect(
            try EmbedTelemetryExpectations.paddedTokens(in: metrics, ref: Self.ref)
                == statistics.subBatches.map { Double($0.paddedTokens) })
    }

    @Test("a failed embed call records one duration with the outcome failed, and no duration with the outcome succeeded")
    func aFailedEmbedCallRecordsOneFailedDuration() async throws {
        let context = try await Self.captureOneFailedCall()

        let metrics = context.metricsFactory
        QueueMetricExpectations.expectDurations(
            try EmbedTelemetryExpectations.durations(in: metrics, ref: Self.ref, outcome: .failed),
            count: Self.oneSpan)
        #expect(throws: TestMetricsError.self) {
            try EmbedTelemetryExpectations.durations(in: metrics, ref: Self.ref, outcome: .succeeded)
        }
    }

    @Test("a failed embed call adds its token count, and records the padded tokens of the sub-batch that failed")
    func aFailedEmbedCallRecordsItsTokensAndPadding() async throws {
        let context = try await Self.captureOneFailedCall()

        let statistics = EmbeddingBatchStatistics(of: Self.embedding.division(of: Self.texts))
        let failedSubBatch = try #require(statistics.subBatches.first)
        let metrics = context.metricsFactory
        #expect(try EmbedTelemetryExpectations.tokenCounts(in: metrics, ref: Self.ref) == [Int64(statistics.tokenCount)])
        #expect(
            try EmbedTelemetryExpectations.paddedTokens(in: metrics, ref: Self.ref) == [Double(failedSubBatch.paddedTokens)])
    }

    @Test("an embed call gives the vector of each text in the order of the texts")
    func anEmbedCallGivesTheVectorsInInputOrder() async throws {
        let (_, vectors) = try await Self.captureOneCall()

        #expect(vectors == Self.texts.map(TracedFakeEmbedding.vector(of:)))
    }
}
