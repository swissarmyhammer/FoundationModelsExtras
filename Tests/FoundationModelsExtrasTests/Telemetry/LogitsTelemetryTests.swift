@testable import FoundationModelsExtras
import MetricsTestKit
import TelemetryTestSupport
import Testing

/// The telemetry of one `logProbabilities` call of a ``PooledLogitsModel``:
/// one logits span with the counts of the call, the call counter and the
/// duration timer of the model.
///
/// Each test calls a ``PooledLogitsModel`` that keeps a hold of a
/// ``FakeLogits``, thus no test needs a model. The import is `@testable`, so
/// a test can read the internal telemetry names.
@Suite("Logits telemetry: a span and metrics for each logProbabilities call")
struct LogitsTelemetryTests {
    /// The key of the model of each call.
    private static let key = ModelPoolKey(ref: "org/logits", role: .llm)

    /// The bytes of ``key`` for its hold: the weights and one session.
    private static let footprintBytes: Int64 = 10

    /// The bytes of one session.
    private static let sessionBytes: Int64 = 2

    /// The first token ID of the prompts. Each token ID of a call has nine
    /// digits, thus no hex trace ID or span ID holds one by chance.
    private static let firstTokenID = 900_000_001

    /// The token count of each prompt of a call.
    private static let promptLengths = [4, 5, 6]

    /// The sum of ``promptLengths``.
    private static let tokenCount = 15

    /// The prompts of each call: one prompt for each of ``promptLengths``,
    /// each a run of new token IDs from ``firstTokenID``.
    private static let prompts: [[Int]] = promptLengths.indices.map { index in
        let start = firstTokenID + promptLengths[..<index].reduce(0, +)
        return Array(start..<(start + promptLengths[index]))
    }

    /// The candidates of each call: the two token IDs after the last token of
    /// the prompts.
    private static let candidates = [firstTokenID + tokenCount, firstTokenID + tokenCount + 1]

    /// Each token ID of a call, as text: the strings that no place of the
    /// capture may hold.
    private static let tokenIDTexts = (prompts.flatMap { $0 } + candidates).map { String($0) }

    /// The text that ``noPlaceHoldsThePromptText()`` tokenizes. It holds `q`
    /// and `z`, which no hex trace ID or span ID holds, thus the text matches
    /// no place of the capture by chance.
    private static let promptText = "qz-which answer is correct"

    /// The count of spans, of calls and of durations of one call.
    private static let oneCall = 1

    /// Makes a model that keeps a hold of `logits`.
    ///
    /// - Parameter logits: The container of the hold.
    /// - Returns: The model.
    /// - Throws: What the load or the cast throws.
    private static func heldModel(of logits: FakeLogits) async throws -> PooledLogitsModel {
        try PooledLogitsModel(
            hold: await ModelPool().acquire(
                key, footprintBytes: footprintBytes, sessionBytes: sessionBytes,
                loader: FixedLoader(container: logits)))
    }

    /// Runs one `logProbabilities` call of ``candidates`` after ``prompts``
    /// in a new capture that forbids each token ID of the call. The capture
    /// keeps the error of the call, thus a test of a failed call uses the
    /// same capture as a test of a call that succeeds.
    ///
    /// - Parameter fails: `true` to make the call throw ``FakeModelRunError``.
    /// - Returns: The capture, and the rows or the error of the call.
    /// - Throws: The error of the capture or of the load.
    private static func captureOneCall(
        fails: Bool = false
    ) async throws -> (context: TelemetryCapture.Context, outcome: Result<[[Double]], any Error>) {
        try await TelemetryCapture.run(forbidding: tokenIDTexts) { context in
            let model = try await heldModel(of: FakeLogits(maximumPromptTokens: nil, failsLogProbabilities: fails))
            do {
                return (context, .success(try await model.logProbabilities(of: candidates, after: prompts)))
            } catch {
                return (context, .failure(error))
            }
        }
    }

    /// Runs one failed `logProbabilities` call with
    /// ``captureOneCall(fails:)``, and expects that the call throws
    /// ``FakeModelRunError``.
    ///
    /// - Returns: The capture.
    /// - Throws: The error of the capture.
    private static func captureOneFailedCall() async throws -> TelemetryCapture.Context {
        let (context, outcome) = try await captureOneCall(fails: true)
        #expect(throws: FakeModelRunError.self) { try outcome.get() }
        return context
    }

    @Test("a logProbabilities call opens one logits span")
    func aCallOpensOneSpan() async throws {
        let (context, _) = try await Self.captureOneCall()

        #expect(LogitsTelemetryExpectations.spans(in: context.spans).count == Self.oneCall)
    }

    @Test("the logits span has the model ref, the prompt count, the candidate count and the token count")
    func theSpanHasTheCounts() async throws {
        let (context, _) = try await Self.captureOneCall()

        let span = try #require(LogitsTelemetryExpectations.spans(in: context.spans).first)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.modelRef) == .string(Self.key.ref.stringValue))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.logitsPromptCount) == .int64(Int64(Self.prompts.count)))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.logitsCandidateCount)
                == .int64(Int64(Self.candidates.count)))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.logitsTokenCount) == .int64(Int64(Self.tokenCount)))
    }

    @Test("a logProbabilities call increments the call counter by one")
    func aCallIncrementsTheCallCounter() async throws {
        let (context, _) = try await Self.captureOneCall()

        #expect(
            try LogitsTelemetryExpectations.callCounts(in: context.metricsFactory, ref: Self.key.ref)
                == [Int64(Self.oneCall)])
    }

    @Test("a logProbabilities call records one duration with the outcome succeeded")
    func aCallRecordsOneDuration() async throws {
        let (context, _) = try await Self.captureOneCall()

        QueueMetricExpectations.expectDurations(
            try LogitsTelemetryExpectations.durations(
                in: context.metricsFactory, ref: Self.key.ref, outcome: .succeeded),
            count: Self.oneCall)
    }

    @Test("a logProbabilities call gives the rows of the container")
    func aCallGivesTheRowsOfTheContainer() async throws {
        let (_, outcome) = try await Self.captureOneCall()

        let expected = try await FakeLogits(maximumPromptTokens: nil)
            .logProbabilities(of: Self.candidates, after: Self.prompts)
        #expect(try outcome.get() == expected)
    }

    @Test("a failed logProbabilities call records the error on the logits span")
    func aFailedCallRecordsTheErrorOnTheSpan() async throws {
        let context = try await Self.captureOneFailedCall()

        let span = try #require(LogitsTelemetryExpectations.spans(in: context.spans).first)
        #expect(span.status?.code == .error)
    }

    @Test("a failed logProbabilities call increments the call counter by one")
    func aFailedCallIncrementsTheCallCounter() async throws {
        let context = try await Self.captureOneFailedCall()

        #expect(
            try LogitsTelemetryExpectations.callCounts(in: context.metricsFactory, ref: Self.key.ref)
                == [Int64(Self.oneCall)])
    }

    @Test("a failed logProbabilities call records one duration with the outcome failed, and none with succeeded")
    func aFailedCallRecordsOneFailedDuration() async throws {
        let context = try await Self.captureOneFailedCall()

        let metrics = context.metricsFactory
        QueueMetricExpectations.expectDurations(
            try LogitsTelemetryExpectations.durations(in: metrics, ref: Self.key.ref, outcome: .failed),
            count: Self.oneCall)
        #expect(throws: TestMetricsError.self) {
            try LogitsTelemetryExpectations.durations(in: metrics, ref: Self.key.ref, outcome: .succeeded)
        }
    }

    @Test("no place of the telemetry holds a token ID of the prompts or of the candidates")
    func noPlaceHoldsATokenID() async throws {
        let (context, _) = try await Self.captureOneCall()

        #expect(context.leaks(forbidding: Self.tokenIDTexts).isEmpty)
    }

    @Test("no place of the telemetry holds the text that the prompt came from")
    func noPlaceHoldsThePromptText() async throws {
        let leaks = try await TelemetryCapture.run(forbidding: []) { context in
            let model = try await Self.heldModel(of: FakeLogits(maximumPromptTokens: nil))
            let prompt = try await model.tokenize(Self.promptText)
            _ = try await model.logProbabilities(of: Self.candidates, after: [prompt])
            return context.leaks(forbidding: [Self.promptText])
        }

        #expect(leaks.isEmpty)
    }
}
