import FoundationModels
@testable import FoundationModelsExtras
import InMemoryTracing
import MetricsTestKit
import TelemetryTestSupport
import Testing
import Tracing

/// The instructions of each session of this suite. Short answers keep each
/// test fast.
private let shortAnswers = "You are a helpful assistant. Answer in as few words as you can."

/// A question with one well-known answer, and that answer.
private enum CapitalQuestion {
    /// The question.
    static let prompt = "What is the capital of France?"
    /// The word that the answer contains.
    static let answer = "paris"
}

/// A question whose answer is a number, and that number.
private enum LegCountQuestion {
    /// The question.
    static let prompt = "How many legs does a spider have?"
    /// The number of legs of a spider.
    static let legCount = 8
}

/// A fact that a session hears, and the question that it asks in a later turn.
private enum RememberedFact {
    /// The color that the session hears.
    static let color = "teal"
    /// The prompt that tells the fact to the session.
    static let statement = "My favorite color is \(color). Remember it, and answer only OK."
    /// The question of the later turn.
    static let question = "What is my favorite color? Answer with the color only."
}

/// The typed answer of the typed respond test.
@Generable
private struct LegCount {
    /// The number of legs.
    @Guide(description: "The number of legs, as a number")
    let legs: Int
}

/// The LLM of the two pooled model suites.
private let pooledModelKey = IntegrationModels.toolCallingLLM

extension RealModelSuites {
    /// `PooledModel` and `PooledSession` with the real
    /// `mlx-community/Qwen3-4B-4bit`. The suite loads the model one time, and
    /// each `PooledModel` of a test finds it resident in the pool of the suite.
    @Suite(
        "Pooled model with a real LLM",
        .sharedLoads(SharedModel(pooledModelKey, footprint: IntegrationModels.toolCallingFootprintBytes)))
    struct PooledModelIntegrationTests {
        @Test("a session of the real model answers a question")
        func aSessionAnswers() async throws {
            let answer = try await Self.respond(to: CapitalQuestion.prompt, in: try SharedModels.required().pool)

            #expect(answer.lowercased().contains(CapitalQuestion.answer), "answer: \(answer)")
        }

        @Test("respond(to:generating:) decodes the answer of the real model as a Generable type")
        func aTypedRespondDecodesTheAnswer() async throws {
            let answer = try await Self.respondWithLegCount(in: try SharedModels.required().pool)

            #expect(answer.legs == LegCountQuestion.legCount)
        }

        @Test("a real session remembers a fact that it heard in an earlier turn")
        func aSessionRemembersAFactOfAnEarlierTurn() async throws {
            let answer = try await Self.askForTheFact(in: try SharedModels.required().pool)

            #expect(answer.lowercased().contains(RememberedFact.color), "answer: \(answer)")
        }

        @Test("a LanguageModelSession over a pooled real model decodes a Generable answer")
        func aLanguageModelSessionDecodesAGenerableAnswer() async throws {
            let answer = try await Self.respondWithLegCountInLanguageModelSession(in: try SharedModels.required().pool)

            #expect(answer.legs == LegCountQuestion.legCount)
        }

        /// Asks the leg count question as a ``LegCount`` in a new
        /// `LanguageModelSession` over a new `PooledModel` of the model of this
        /// suite. The session and the model go when the call returns.
        ///
        /// - Parameter pool: The pool of the suite.
        /// - Returns: The typed answer.
        /// - Throws: The error of the generation or of the decode.
        private static func respondWithLegCountInLanguageModelSession(in pool: ModelPool) async throws -> LegCount {
            let session = LanguageModelSession(
                model: PooledModel(ref: pooledModelKey.ref, pool: pool), instructions: shortAnswers)
            return try await session.respond(to: LegCountQuestion.prompt, generating: LegCount.self).content
        }

        /// Asks `prompt` in a new session of the model of this suite. The
        /// session goes when the call returns.
        ///
        /// - Parameters:
        ///   - prompt: The question.
        ///   - pool: The pool of the suite.
        /// - Returns: The text of the answer.
        /// - Throws: The error of the generation.
        private static func respond(to prompt: String, in pool: ModelPool) async throws -> String {
            let session = try await PooledModel(ref: pooledModelKey.ref, pool: pool).session(instructions: shortAnswers)
            return try await session.respond(to: prompt)
        }

        /// Asks the leg count question as a ``LegCount`` in a new session of
        /// the model of this suite. The session goes when the call returns.
        ///
        /// - Parameter pool: The pool of the suite.
        /// - Returns: The typed answer.
        /// - Throws: The error of the generation or of the decode.
        private static func respondWithLegCount(in pool: ModelPool) async throws -> LegCount {
            let session = try await PooledModel(ref: pooledModelKey.ref, pool: pool).session(instructions: shortAnswers)
            return try await session.respond(to: LegCountQuestion.prompt, generating: LegCount.self)
        }

        /// Tells the fact to a new session, and asks the same session for the
        /// fact in a later turn. The session goes when the call returns.
        ///
        /// - Parameter pool: The pool of the suite.
        /// - Returns: The text of the answer of the later turn.
        /// - Throws: The error of a generation.
        private static func askForTheFact(in pool: ModelPool) async throws -> String {
            let session = try await PooledModel(ref: pooledModelKey.ref, pool: pool).session(instructions: shortAnswers)
            _ = try await session.respond(to: RememberedFact.statement)
            return try await session.respond(to: RememberedFact.question)
        }
    }

    /// The generate telemetry of `PooledModel` with the real
    /// `mlx-community/Qwen3-4B-4bit`. The test examines the cold call that
    /// loads the model, thus it loads the model in a pool of its own. It is
    /// not in the suite of the shared load: its eviction would remove the
    /// weights under the shared hold, because `MLXLanguageModel` keeps the
    /// weights in one model cache for each process.
    @Suite("Pooled model generate telemetry with a real LLM")
    struct PooledModelTelemetryIntegrationTests {
        @Test(
            """
            two calls of a LanguageModelSession over a pooled real model open a cold and then a warm generate \
            span, record a first token before the end of each call, and carry no prompt and no answer
            """)
        func twoCallsOpenAColdAndThenAWarmGenerateSpan() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.captureColdAndWarmCalls(in: pool)
            try await IntegrationModels.waitForEviction(of: pooledModelKey, in: pool)

            let context = outcome.context
            let generateSpans = CapturedSpans.spans(named: ExtrasTelemetry.SpanName.generate, in: context.spans)
            let load = try CapturedSpans.onlySpan(named: ExtrasTelemetry.SpanName.modelLoad, in: context.spans)
            try #require(generateSpans.count == outcome.answers.count, "one generate span for each call")
            GenerateTelemetryExpectations.expectColdThenWarm(generateSpans, ref: pooledModelKey.ref)
            #expect(load.parentSpanID == generateSpans.first?.spanID, "the load span is a child of the cold span")
            try GenerateTelemetryExpectations.expectFirstTokenBeforeEnd(
                in: context.metricsFactory, ref: pooledModelKey.ref, callCount: outcome.answers.count)
            // A short answer, for example one digit, can occur in a span id.
            // An answer with the word of the question is a text that no
            // telemetry place holds by chance.
            try #require(
                outcome.answers.allSatisfy { $0.lowercased().contains(CapitalQuestion.answer) },
                "answers: \(outcome.answers)")
            let leaks = context.leaks(forbidding: outcome.answers)
            #expect(leaks.isEmpty, "the telemetry holds an answer: \(leaks)")
            #expect(!context.logRecords.isEmpty, "the capture holds the log records of the calls")
            #expect(!context.metricRecords.isEmpty, "the capture holds the metrics of the calls")
        }

        /// Asks the capital question two times in one new `LanguageModelSession`
        /// over a new `PooledModel` of the model of this suite, in a telemetry
        /// capture. The first call loads the model, and the second call finds
        /// it resident. The capture forbids the prompt and the instructions in
        /// each span, log record and metric. The session and the model go when
        /// the call returns.
        ///
        /// - Parameter pool: The pool of the test.
        /// - Returns: The capture of the two calls, and the text of each answer.
        /// - Throws: The error of the load or of a generation.
        private static func captureColdAndWarmCalls(in pool: ModelPool) async throws -> GenerateTelemetryOutcome {
            try await TelemetryCapture.run(forbidding: [CapitalQuestion.prompt, shortAnswers]) { context in
                let session = LanguageModelSession(
                    model: PooledModel(ref: pooledModelKey.ref, pool: pool), instructions: shortAnswers)
                let coldAnswer = try await session.respond(to: CapitalQuestion.prompt).content
                let warmAnswer = try await session.respond(to: CapitalQuestion.prompt).content
                return GenerateTelemetryOutcome(context: context, answers: [coldAnswer, warmAnswer])
            }
        }
    }
}

/// What the generate telemetry test observed.
private struct GenerateTelemetryOutcome {
    /// The capture of the calls.
    let context: TelemetryCapture.Context
    /// The text of the answer of each call, in the order of the calls.
    let answers: [String]
}

/// The checks of the generate telemetry of real calls.
///
/// The unit target has the same checks for a stub model, but a test of this
/// package cannot see the unit target. Thus these checks read the span
/// attributes and the timers here.
private enum GenerateTelemetryExpectations {
    /// Expects that each generate span carries the model ref and no guided
    /// flag, that the first span is cold, and that the second span is warm.
    ///
    /// - Parameters:
    ///   - spans: The generate spans of a cold call and then a warm call.
    ///   - ref: The model of the calls.
    static func expectColdThenWarm(_ spans: [FinishedInMemorySpan], ref: ModelRef) {
        let coldFlags = spans.map { $0.attributes.get(ExtrasTelemetry.AttributeKey.generateCold) }
        #expect(coldFlags == [.bool(true), .bool(false)], "the cold flag of each call")
        for span in spans {
            #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.modelRef) == .string(ref.stringValue))
            #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.generateGuided) == .bool(false))
        }
    }

    /// Expects one time-to-first-token value and one duration value for each
    /// call, each time to first token more than zero and not more than the
    /// duration of its call.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the calls recorded into.
    ///   - ref: The model of the calls.
    ///   - callCount: The count of calls, each of which succeeded.
    /// - Throws: When `metrics` has no such timer.
    static func expectFirstTokenBeforeEnd(in metrics: TestMetrics, ref: ModelRef, callCount: Int) throws {
        let firstTokens = try succeededTimerValues(
            of: ExtrasTelemetry.MetricName.generateTimeToFirstToken, in: metrics, ref: ref)
        let durations = try succeededTimerValues(of: ExtrasTelemetry.MetricName.generateDuration, in: metrics, ref: ref)
        #expect(firstTokens.count == callCount)
        #expect(durations.count == callCount)
        #expect(firstTokens.allSatisfy { $0 > 0 }, "times to first token: \(firstTokens)")
        #expect(
            zip(firstTokens, durations).allSatisfy { $0 <= $1 },
            "times to first token: \(firstTokens); durations: \(durations)")
    }

    /// Gives the values of the generate timer `label` of `ref` for the calls
    /// that succeeded.
    ///
    /// - Parameters:
    ///   - label: The label of the timer.
    ///   - metrics: The factory that the calls recorded into.
    ///   - ref: The model of the calls.
    /// - Returns: The values in nanoseconds, in the order of the calls.
    /// - Throws: When `metrics` has no such timer.
    private static func succeededTimerValues(of label: String, in metrics: TestMetrics, ref: ModelRef) throws -> [Int64] {
        let dimensions = [
            (ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue),
            (ExtrasTelemetry.DimensionKey.modelOutcome, ModelOperationOutcome.succeeded.rawValue),
        ]
        return try metrics.expectTimer(label, dimensions).values
    }
}
