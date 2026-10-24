import FoundationModels
@testable import FoundationModelsExtras
import Metrics
import MetricsTestKit
import TelemetryTestSupport
import Testing

/// The typed answer of the typed respond test and of the README example.
@Generable
private struct Answer {
    /// A number.
    let number: Int
}

/// A ``PooledModel`` loads nothing when you make it. Its first session loads
/// the LLM into the pool. Each session keeps a hold of the model. Only the
/// call into the model waits: the stub model holds a FIFO lock for each
/// generation, as MLX does, and a tool body runs outside each lock.
@Suite("Pooled model: sessions of an LLM by name, with one load and one lock for each generation")
struct PooledModelTests {
    /// The key of the LLM that the tests load.
    private static let key = ModelPoolKey(ref: "org/chat", role: .llm)

    /// The name of the loader that ``stubLoader(script:log:loadsMayEnd:)`` makes.
    private static let loaderName = "A"

    /// The log entry of one load of ``key`` by the loader that
    /// ``stubLoader(script:log:loadsMayEnd:)`` makes.
    private static let loadEntry = "load \(key.ref.stringValue) by \(loaderName)"

    /// The first prompt of a test.
    private static let firstPrompt = "one"

    /// The second prompt of a test.
    private static let secondPrompt = "two"

    /// The number in the answer of the typed respond test.
    private static let typedAnswerNumber = 7

    /// The answer of the stub model in the typed respond test: an
    /// ``Answer`` as JSON.
    private static let typedAnswerJSON = #"{"number": \#(typedAnswerNumber)}"#

    /// Makes a loader that writes each load to `log`, and gives a
    /// ``StubLanguageModel`` that plays `script`.
    ///
    /// - Parameters:
    ///   - script: The script of the model.
    ///   - log: The log of the loads, the measures and the evictions.
    ///   - loadsMayEnd: A load ends only after this stream finishes. The
    ///     default stream is finished, so a load ends at once.
    /// - Returns: The loader.
    private static func stubLoader(
        script: StubLanguageModelScript,
        log: Recorder<String>,
        loadsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() }
    ) -> RecordingLoader {
        let model = StubLanguageModel(script: script)
        return RecordingLoader(name: loaderName, log: log, loadsMayEnd: loadsMayEnd, makeModel: { _ in model })
    }

    /// A session whose first respond call blocks in the stub model.
    private struct BlockedCall {
        /// The model of the session.
        let model: PooledModel
        /// The session.
        let session: PooledSession
        /// The script of the stub model, with the FIFO lock of its
        /// generations.
        let script: StubLanguageModelScript
        /// The log of the generation calls of the stub model.
        let log: Recorder<String>
        /// Finish this to end the first call.
        let endFirstCall: AsyncStream<Void>.Continuation
        /// The task of the first call, which runs.
        let firstCall: Task<String, any Error>
    }

    /// Makes a session of a stub model whose first call blocks, and starts
    /// that call with ``firstPrompt``. Returns when the call runs.
    ///
    /// - Returns: The session and its running first call.
    /// - Throws: An `ExpectationFailedError` when the first call never ran.
    private static func startBlockedCall() async throws -> BlockedCall {
        let log = Recorder<String>()
        let (firstCallMayEnd, endFirstCall) = AsyncStream.makeStream(of: Void.self)
        let script = StubLanguageModelScript(log: log, firstCallMayEnd: firstCallMayEnd)
        let pool = ModelPool(loader: stubLoader(script: script, log: Recorder()))
        let model = PooledModel(ref: key.ref, pool: pool)
        let session = try await model.session()
        let firstCall = Task { try await session.respond(to: firstPrompt) }
        try await waitUntilTheFirstCallRuns(firstCall, log: log)
        return BlockedCall(
            model: model, session: session, script: script, log: log, endFirstCall: endFirstCall, firstCall: firstCall)
    }

    /// Waits until the stub model begins the call of ``firstPrompt``, or until
    /// `call` ends first.
    ///
    /// - Parameters:
    ///   - call: The task of the first call.
    ///   - log: The log of the generation calls of the stub model.
    /// - Throws: An `ExpectationFailedError` when the call never began.
    private static func waitUntilTheFirstCallRuns(
        _ call: Task<String, any Error>, log: Recorder<String>
    ) async throws {
        let begin = "begin \(firstPrompt)"
        await Waits.untilFirstEnds({ await log.waitUntil { $0.contains(begin) } }, { _ = await call.result })
        try #require(log.values == [begin])
    }

    /// Waits until the loader of `log` starts the load of ``key``, or until
    /// `callers` end first.
    ///
    /// - Parameters:
    ///   - log: The log of a loader that ``stubLoader(script:log:loadsMayEnd:)``
    ///     made.
    ///   - callers: The tasks that need the load.
    /// - Throws: An `ExpectationFailedError` when the load did not start.
    private static func waitUntilTheLoadRuns<Value: Sendable>(
        in log: Recorder<String>, for callers: [Task<Value, any Error>]
    ) async throws {
        await Waits.untilFirstEnds(
            { await log.waitUntil { $0.contains(loadEntry) } },
            { for caller in callers { _ = await caller.result } })
        try #require(loads(in: log) == [loadEntry])
    }

    /// The loads in `log`.
    ///
    /// - Parameter log: The log of a loader that ``stubLoader(script:log:loadsMayEnd:)``
    ///   made.
    /// - Returns: Each load entry, in order.
    private static func loads(in log: Recorder<String>) -> [String] {
        log.values.filter { $0.hasPrefix("load ") }
    }

    @Test("a pooled model made from a name loads nothing")
    func aPooledModelLoadsNothing() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: log))

        let model = PooledModel(ref: Self.key.ref, pool: pool)
        // An admission job ends after each load that is in the admission queue now.
        try await pool.admit { _ in }

        withExtendedLifetime(model) {
            #expect(pool.footprint == ModelPoolFootprint(resident: [:], loadingBytes: 0))
            #expect(log.values.isEmpty)
        }
    }

    @Test("a prewarm whose load fails writes one error record with the error type and the model ref")
    func aFailedPrewarmWritesOneErrorRecord() async throws {
        let loader = RecordingLoader(name: Self.loaderName, log: Recorder<String>(), failingLoads: 1)
        let model = PooledModel(ref: Self.key.ref, pool: ModelPool(loader: loader))

        let records = try await TelemetryCapture.run(forbidding: []) { context in
            model.prewarm(transcript: Transcript())
            return await context.waitForErrorRecords()
        }

        let expected = TelemetryCapture.LogRecord(
            level: .error,
            message: "\(ExtrasTelemetry.PoolLogMessage.prewarmFailed)",
            metadata: [
                ExtrasTelemetry.LogMetadataKey.errorType: .string(ExtrasTelemetry.errorType(of: FakeLoadError())),
                ExtrasTelemetry.LogMetadataKey.modelRef: .string(Self.key.ref.stringValue),
            ],
            label: ExtrasTelemetry.logLabel
        )
        #expect(records == [expected])
    }

    @Test("the first session loads the model of the name with the loader of the pool, and answers")
    func theFirstSessionLoadsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: log))
        let model = PooledModel(ref: Self.key.ref, pool: pool)

        let session = try await model.session()
        let answer = try await session.respond(to: Self.firstPrompt)

        #expect(answer == Self.firstPrompt)
        #expect(session.model == Self.key.ref)
        #expect(pool.isResident(Self.key))
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("two concurrent first sessions of two pooled models of one name make one load")
    func twoSessionsOfOneNameMakeOneLoad() async throws {
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: log, loadsMayEnd: loadsMayEnd))
        let first = PooledModel(ref: Self.key.ref, pool: pool)
        let second = PooledModel(ref: Self.key.ref, pool: pool)

        // Each session starts in a task of its own, not in an `async let`. A
        // failed wait then leaves the scope at once, and the deferred finish
        // ends the load.
        defer { endLoads.finish() }
        let firstSession = Task { try await first.session() }
        let secondSession = Task { try await second.session() }
        try await Self.waitUntilTheLoadRuns(in: log, for: [firstSession, secondSession])
        endLoads.finish()
        let sessions = try await [firstSession.value, secondSession.value]

        #expect(sessions.map(\.model) == [Self.key.ref, Self.key.ref])
        #expect(pool.residentModelCount == 1)
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    /// The load joins that one caller adds when it waits for the load of an
    /// other caller.
    private static let oneLoadJoin: [Int64] = [1]

    /// The value that the load of the resident hold test gives.
    private static let residentValue = "resident"

    @Test("a second caller of one resident hold that waits for the running load adds one load join, the first adds none")
    func aCallerThatJoinsTheRunningLoadAddsOneLoadJoin() async throws {
        let log = Recorder<String>()
        let (loadMayEnd, endLoad) = AsyncStream.makeStream(of: Void.self)
        defer { endLoad.finish() }
        let hold = ResidentHold<String> {
            log.append(Self.loadEntry)
            for await _ in loadMayEnd {}
            return Self.residentValue
        }

        // Each caller starts in a task of its own, not in an `async let`. A
        // failed wait then leaves the scope at once, and the deferred finish
        // ends the load. The capture tests each metric record, thus the wait
        // for the load join needs no poll.
        let (values, metrics) = try await TelemetryCapture.run(forbidding: []) { context in
            try await withMetricsFactory(context.observedMetricsFactory) {
                let first = Task { try await hold.loaded() }
                await Waits.untilFirstEnds(
                    { await log.waitUntil { $0.contains(Self.loadEntry) } }, { _ = await first.result })
                try #require(log.values == [Self.loadEntry])
                let second = Task { try await hold.loaded() }
                await Waits.untilFirstEnds(
                    { await context.wait { (try? PoolMetricExpectations.loadJoins(in: $0.metricsFactory)) != nil } },
                    { _ = await second.result })
                try #require(try PoolMetricExpectations.loadJoins(in: context.metricsFactory) == Self.oneLoadJoin)
                endLoad.finish()
                return (try await [first.value, second.value], context.metricsFactory)
            }
        }

        #expect(values == [Self.residentValue, Self.residentValue])
        #expect(try PoolMetricExpectations.loadJoins(in: metrics) == Self.oneLoadJoin)
        #expect(log.values == [Self.loadEntry])
    }

    @Test("two sessions of one model never run a generation at the same time, and the generations run in FIFO order")
    func twoSessionsRespondOneAtATime() async throws {
        let blocked = try await Self.startBlockedCall()
        let secondSession = try await blocked.model.session()

        // The stub model holds a FIFO lock for each generation, as MLX does,
        // thus the second respond waits for that lock.
        let secondCall = Task { try await secondSession.respond(to: Self.secondPrompt) }
        await Waits.untilFirstEnds(
            { await blocked.script.lock.queued.waitUntil { $0.contains(Self.secondPrompt) } },
            { _ = await secondCall.result })
        try #require(blocked.script.lock.queued.values == [Self.secondPrompt])
        blocked.endFirstCall.finish()
        let answers = try await [blocked.firstCall.value, secondCall.value]

        #expect(answers == [Self.firstPrompt, Self.secondPrompt])
        #expect(blocked.log.values == [
            "begin \(Self.firstPrompt)", "end \(Self.firstPrompt)", "begin \(Self.secondPrompt)", "end \(Self.secondPrompt)",
        ])
    }

    @Test("a PooledSession respond runs in no job of the queue of the model")
    func aPooledSessionRespondRunsInNoQueueJob() async throws {
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: Recorder()))
        let metrics = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await PooledModel(ref: Self.key.ref, pool: pool).session().respond(to: Self.firstPrompt)
            return context.metricsFactory
        }

        #expect(throws: TestMetricsError.self) {
            try QueueMetricExpectations.depth(
                in: metrics,
                queue: QueueMetricDimensions.queue(named: QueueName.model.rawValue, model: Self.key.ref.stringValue))
        }
    }

    @Test("a tool body that calls respond on an other PooledSession of the same model gets that answer, and the call ends")
    func aToolThatUsesTheSameModelCompletes() async throws {
        let script = StubLanguageModelScript(toolName: AskSessionTool.toolName, toolPrompt: Self.firstPrompt)
        let model = PooledModel(ref: Self.key.ref, pool: ModelPool(loader: Self.stubLoader(script: script, log: Recorder())))
        let helper = try await model.session()
        let toolAnswers = Recorder<String>()
        let tool = AskSessionTool(session: helper, prompt: Self.secondPrompt, answers: toolAnswers)
        let session = try await model.session(tools: [tool])

        let answer = try await session.respond(to: Self.firstPrompt)

        #expect(toolAnswers.values == [Self.secondPrompt])
        #expect(answer == Self.firstPrompt)
    }

    @Test(
        "two PooledSessions of one model take turns for each generation: a generation of one runs while a tool body of the other waits",
        .timeLimit(.minutes(1)))
    func twoSessionsTakeTurnsForEachGeneration() async throws {
        let script = StubLanguageModelScript(toolName: WaitingTool.toolName, toolPrompt: Self.firstPrompt)
        let model = PooledModel(ref: Self.key.ref, pool: ModelPool(loader: Self.stubLoader(script: script, log: Recorder())))
        let toolLog = Recorder<String>()
        let (toolMayEnd, endTool) = AsyncStream.makeStream(of: Void.self)
        defer { endTool.finish() }
        let first = try await model.session(tools: [WaitingTool(log: toolLog, mayEnd: toolMayEnd)])
        let second = try await model.session()

        let firstCall = Task { try await first.respond(to: Self.firstPrompt) }
        await toolLog.waitUntil(holds: WaitingTool.beginEntry, orUntilEndOf: firstCall)
        try #require(toolLog.values == [WaitingTool.beginEntry])
        let secondCall = Task { try await second.respond(to: Self.secondPrompt) }
        // The wait ends at a cancel, thus the time limit ends a call that
        // waits for the tool body of the other session.
        await script.log.waitUntil { $0.contains("end \(Self.secondPrompt)") }
        let secondAnswer = try await secondCall.value
        let toolWaitedForTheWholeSecondCall = toolLog.values == [WaitingTool.beginEntry]
        endTool.finish()
        let firstAnswer = try await firstCall.value

        #expect(secondAnswer == Self.secondPrompt)
        #expect(toolWaitedForTheWholeSecondCall)
        #expect(firstAnswer == Self.firstPrompt)
    }

    @Test("the model stays resident while a session exists, and is evicted after the session goes")
    func theLastSessionEvictsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: log))
        var session: PooledSession? = try await PooledModel(ref: Self.key.ref, pool: pool).session()

        let answer = try await session?.respond(to: Self.firstPrompt)
        try await pool.waitForTheEarlierAdmissionJobs()
        let residentWhileTheSessionExists = pool.isResident(Self.key)
        session = nil
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(residentWhileTheSessionExists)
        #expect(answer == Self.firstPrompt)
        #expect(Self.loads(in: log) == [Self.loadEntry])
        #expect(!pool.isResident(Self.key))
    }

    @Test("respond(to:generating:) decodes the answer of the model as a Generable type")
    func aTypedRespondDecodesTheAnswer() async throws {
        let script = StubLanguageModelScript(answer: { _ in Self.typedAnswerJSON })
        let pool = ModelPool(loader: Self.stubLoader(script: script, log: Recorder()))
        let session = try await PooledModel(ref: Self.key.ref, pool: pool).session()

        let answer = try await session.respond(to: Self.firstPrompt, generating: Answer.self)

        #expect(answer.number == Self.typedAnswerNumber)
    }

    @Test("the README example: a session answers with text and with a Generable type")
    func readmePooledModelExample() async throws {
        let log = Recorder<String>()
        let script = StubLanguageModelScript(answer: { _ in Self.typedAnswerJSON })
        let pool = ModelPool(loader: Self.stubLoader(script: script, log: log))

        // README example: begin
        // Loads nothing now. The first session loads the model into the pool.
        let qwen = PooledModel(ref: "mlx-community/Qwen3-4B-4bit", pool: pool)
        let session = try await qwen.session(instructions: "Answer with one number.")
        let text = try await session.respond(to: "How many legs has a cat?")
        let typed = try await session.respond(to: "And a spider?", generating: Answer.self)
        // README example: end

        #expect(text == Self.typedAnswerJSON)
        #expect(typed.number == Self.typedAnswerNumber)
        #expect(Self.loads(in: log) == ["load \(session.model.stringValue) by \(Self.loaderName)"])
    }

    @Test("a LanguageModelSession over a pooled model loads nothing until its first respond, which loads and answers")
    func aLanguageModelSessionLoadsOnItsFirstRespond() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: log))
        let session = LanguageModelSession(model: PooledModel(ref: Self.key.ref, pool: pool))
        // An admission job ends after each load that is in the admission queue now.
        try await pool.admit { _ in }
        let loadsBeforeTheFirstRespond = Self.loads(in: log)

        let answer = try await session.respond(to: Self.firstPrompt).content

        #expect(loadsBeforeTheFirstRespond.isEmpty)
        #expect(answer == Self.firstPrompt)
        #expect(pool.isResident(Self.key))
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("concurrent first responds of two LanguageModelSessions over one pooled model make one load and one hold")
    func concurrentFirstRespondsMakeOneLoad() async throws {
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: log, loadsMayEnd: loadsMayEnd))
        let model = PooledModel(ref: Self.key.ref, pool: pool)
        let first = LanguageModelSession(model: model)
        let second = LanguageModelSession(model: model)

        // Each respond starts in a task of its own, not in an `async let`. A
        // failed wait then leaves the scope at once, and the deferred finish
        // ends the load.
        defer { endLoads.finish() }
        let firstAnswer = Task { try await first.respond(to: Self.firstPrompt).content }
        let secondAnswer = Task { try await second.respond(to: Self.secondPrompt).content }
        try await Self.waitUntilTheLoadRuns(in: log, for: [firstAnswer, secondAnswer])
        endLoads.finish()
        let answers = try await Set([firstAnswer.value, secondAnswer.value])

        #expect(answers == [Self.firstPrompt, Self.secondPrompt])
        #expect(Self.loads(in: log) == [Self.loadEntry])
        #expect(pool.residentModelCount == 1)
    }

    @Test("the responds of two LanguageModelSessions over one pooled model run one at a time, in FIFO order")
    func languageModelSessionsRespondOneAtATime() async throws {
        let log = Recorder<String>()
        let (firstCallMayEnd, endFirstCall) = AsyncStream.makeStream(of: Void.self)
        let script = StubLanguageModelScript(log: log, firstCallMayEnd: firstCallMayEnd)
        let pool = ModelPool(loader: Self.stubLoader(script: script, log: Recorder()))
        let model = PooledModel(ref: Self.key.ref, pool: pool)

        // The stub model holds a FIFO lock for each generation, as MLX does,
        // thus the second respond waits for that lock.
        let firstCall = Task { try await LanguageModelSession(model: model).respond(to: Self.firstPrompt).content }
        try await Self.waitUntilTheFirstCallRuns(firstCall, log: log)
        let secondCall = Task { try await LanguageModelSession(model: model).respond(to: Self.secondPrompt).content }
        await Waits.untilFirstEnds(
            { await script.lock.queued.waitUntil { $0.contains(Self.secondPrompt) } }, { _ = await secondCall.result })
        try #require(script.lock.queued.values == [Self.secondPrompt])
        endFirstCall.finish()
        let answers = try await [firstCall.value, secondCall.value]

        #expect(answers == [Self.firstPrompt, Self.secondPrompt])
        #expect(log.values == [
            "begin \(Self.firstPrompt)", "end \(Self.firstPrompt)", "begin \(Self.secondPrompt)", "end \(Self.secondPrompt)",
        ])
    }

    @Test("the README example: a LanguageModelSession over a pooled model decodes a Generable answer")
    func readmeLanguageModelSessionExample() async throws {
        let log = Recorder<String>()
        let script = StubLanguageModelScript(answer: { _ in Self.typedAnswerJSON })
        let pool = ModelPool(loader: Self.stubLoader(script: script, log: log))

        // README example: begin
        // Loads nothing now. The first respond call loads the model into the pool.
        let qwen = PooledModel(ref: "mlx-community/Qwen3-4B-4bit", pool: pool)
        let session = LanguageModelSession(model: qwen, instructions: "Answer with one number.")
        let typed = try await session.respond(to: "How many legs has a cat?", generating: Answer.self).content
        // README example: end

        #expect(typed.number == Self.typedAnswerNumber)
        #expect(Self.loads(in: log) == ["load mlx-community/Qwen3-4B-4bit by \(Self.loaderName)"])
    }

    @Test("the model stays resident while a LanguageModelSession over a pooled model exists, and is evicted after it goes")
    func theLastLanguageModelSessionEvictsTheModel() async throws {
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: Recorder()))
        var session: LanguageModelSession? = LanguageModelSession(model: PooledModel(ref: Self.key.ref, pool: pool))
        _ = try await session?.respond(to: Self.firstPrompt)

        try await pool.waitForTheEarlierAdmissionJobs()
        let residentWhileTheSessionExists = pool.isResident(Self.key)
        session = nil
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(residentWhileTheSessionExists)
        #expect(!pool.isResident(Self.key))
    }

    @Test("a respond over a pooled model whose container is not a LanguageModel gives a clear error, and keeps no hold")
    func aRespondOnAContainerThatIsNotALanguageModelThrows() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let session = LanguageModelSession(model: PooledModel(ref: Self.key.ref, pool: pool))
        let expected = PooledSessionError.notALanguageModel(key: Self.key, containerType: "FakeModel")

        await #expect(throws: expected) { try await session.respond(to: Self.firstPrompt) }
        try await pool.waitForTheEarlierAdmissionJobs()
        #expect(!pool.isResident(Self.key))
    }

    @Test("a session on a container that is not a LanguageModel gives a clear error, and keeps no hold")
    func aContainerThatIsNotALanguageModelThrows() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let model = PooledModel(ref: Self.key.ref, pool: pool)
        let expected = PooledSessionError.notALanguageModel(key: Self.key, containerType: "FakeModel")

        await #expect(throws: expected) { try await model.session() }
        #expect(expected.errorDescription?.contains("LanguageModel") == true)
        try await pool.waitForTheEarlierAdmissionJobs()
        #expect(!pool.isResident(Self.key))
    }
}

/// A tool that opens one span named ``ExtrasTelemetry/SpanName/tool``
/// through ``TracedCall``, and answers with a fixed text. A parent test reads
/// the parent of that span.
private struct SpanProbeTool: Tool {
    /// The tool takes no argument.
    @Generable
    struct Arguments {}

    /// The model-facing name of the tool.
    static let toolName = "qz_probe"

    /// The text that each call gives.
    static let output = "probed"

    /// The model-facing name of the tool.
    let name = Self.toolName

    /// What the tool does.
    let description = "Opens one tool span."

    /// Opens one tool span, and gives ``output``.
    ///
    /// - Parameter arguments: No argument.
    /// - Returns: ``output``.
    /// - Throws: Never. `throws` comes from the `Tool` requirement.
    func call(arguments: Arguments) async throws -> String {
        try await TracedCall.run(ExtrasTelemetry.SpanName.tool, logger: ExtrasTelemetry.makeLogger()) { _ in
            Self.output
        }
    }
}

/// A tool that asks an other ``PooledSession`` one prompt, writes the answer
/// to a log, and gives the answer. The other session can use the same model
/// as the session that calls the tool.
private struct AskSessionTool: Tool {
    /// The tool takes no argument.
    @Generable
    struct Arguments {}

    /// The model-facing name of the tool.
    static let toolName = "qz_ask"

    /// The model-facing name of the tool.
    let name = Self.toolName

    /// What the tool does.
    let description = "Asks an other session."

    /// The session that the tool asks.
    let session: PooledSession

    /// The prompt that the tool gives to ``session``.
    let prompt: String

    /// The log of the answers of ``session``.
    let answers: Recorder<String>

    /// Asks ``session``, writes its answer to ``answers``, and gives it.
    ///
    /// - Parameter arguments: No argument.
    /// - Returns: The answer of ``session``.
    /// - Throws: The error of the respond call of ``session``.
    func call(arguments: Arguments) async throws -> String {
        let answer = try await session.respond(to: prompt)
        answers.append(answer)
        return answer
    }
}

/// A tool that writes ``beginEntry`` to a log, and then waits until a stream
/// finishes. A test holds the tool body while other work runs.
private struct WaitingTool: Tool {
    /// The tool takes no argument.
    @Generable
    struct Arguments {}

    /// The model-facing name of the tool.
    static let toolName = "qz_wait"

    /// The log entry of the start of the tool body.
    static let beginEntry = "tool begin"

    /// The text that each call gives.
    static let output = "waited"

    /// The model-facing name of the tool.
    let name = Self.toolName

    /// What the tool does.
    let description = "Waits for the test."

    /// The log that gets ``beginEntry``.
    let log: Recorder<String>

    /// The tool body ends only after this stream finishes.
    let mayEnd: AsyncStream<Void>

    /// Writes ``beginEntry``, waits until ``mayEnd`` finishes, and gives
    /// ``output``.
    ///
    /// - Parameter arguments: No argument.
    /// - Returns: ``output``.
    /// - Throws: Never. `throws` comes from the `Tool` requirement.
    func call(arguments: Arguments) async throws -> String {
        log.append(Self.beginEntry)
        for await _ in mayEnd {}
        return Self.output
    }
}

/// The generate telemetry of a pooled model: one generate span for each
/// generation call, with the model ref, the guided flag and the cold flag,
/// the time-to-first-token and duration timers, and the token metrics when
/// the model gives token counts.
extension PooledModelTests {
    /// The first prompt of a generate telemetry test. It holds `q` and `z`,
    /// which no hex trace id or span id holds, thus the prompt matches no
    /// place of the capture by chance. The stub answers with its prompts,
    /// thus each answer holds a prompt too.
    private static let telemetryPrompt = "qz-how-many-legs"

    /// The second prompt of a generate telemetry test.
    private static let secondTelemetryPrompt = "qz-and-a-spider"

    /// The input token count of ``reportedUsage``.
    private static let reportedInputTokens = 30

    /// The cached token count of ``reportedUsage``: the part of its input
    /// that the prompt cache reused.
    private static let reportedCachedTokens = 20

    /// The output token count of ``reportedUsage``.
    private static let reportedOutputTokens = 12

    /// The input token count of ``toolRoundUsage``.
    private static let toolRoundInputTokens = 40

    /// The cached token count of ``toolRoundUsage``.
    private static let toolRoundCachedTokens = 10

    /// The output token count of ``toolRoundUsage``.
    private static let toolRoundOutputTokens = 5

    /// The input token count of ``answerRoundUsage``: the whole context
    /// again, now with the tool call and its output.
    private static let answerRoundInputTokens = 55

    /// The cached token count of ``answerRoundUsage``: most of its input.
    private static let answerRoundCachedTokens = 40

    /// The output token count of ``answerRoundUsage``.
    private static let answerRoundOutputTokens = 7

    /// The usage that the stub of a token test gives for each call: a round
    /// whose prompt cache reused part of the context.
    private static let reportedUsage = StubTokenUsage(
        input: reportedInputTokens, cached: reportedCachedTokens, output: reportedOutputTokens)

    /// The usage of the first round of a token test with a tool call: the
    /// round that asks for the tool.
    private static let toolRoundUsage = StubTokenUsage(
        input: toolRoundInputTokens, cached: toolRoundCachedTokens, output: toolRoundOutputTokens)

    /// The usage of the second round of a token test with a tool call: the
    /// round that answers. It reads the whole context again, most of it from
    /// the prompt cache.
    private static let answerRoundUsage = StubTokenUsage(
        input: answerRoundInputTokens, cached: answerRoundCachedTokens, output: answerRoundOutputTokens)

    /// The number of generation calls of a test with one call.
    private static let oneCall = 1

    /// The number of generation calls of a test with two calls.
    private static let twoCalls = 2

    /// Runs `body` in a new capture that forbids each prompt of the generate
    /// telemetry tests, and thus each answer of the stub to them.
    ///
    /// - Parameter body: The calls of the test.
    /// - Returns: The capture.
    /// - Throws: The error of `body` or of the capture.
    private static func captureGenerate(
        _ body: nonisolated(nonsending) () async throws -> Void
    ) async throws -> TelemetryCapture.Context {
        try await TelemetryCapture.run(forbidding: [telemetryPrompt, secondTelemetryPrompt]) { context in
            try await body()
            return context
        }
    }

    /// Makes a pooled model of a stub that plays `script`, in a new pool.
    ///
    /// - Parameter script: The script of the stub.
    /// - Returns: The pooled model, which loads nothing yet.
    private static func pooledModel(playing script: StubLanguageModelScript = StubLanguageModelScript()) -> PooledModel {
        PooledModel(ref: key.ref, pool: ModelPool(loader: stubLoader(script: script, log: Recorder())))
    }

    /// Runs ``telemetryPrompt`` and then ``secondTelemetryPrompt`` through
    /// one `LanguageModelSession` over a pooled model of a stub that plays
    /// `script`, in a new capture.
    ///
    /// - Parameter script: The script of the stub.
    /// - Returns: The capture.
    /// - Throws: The error of a call or of the capture.
    private static func captureTwoResponds(
        playing script: StubLanguageModelScript = StubLanguageModelScript()
    ) async throws -> TelemetryCapture.Context {
        try await captureGenerate {
            let session = LanguageModelSession(model: pooledModel(playing: script))
            _ = try await session.respond(to: telemetryPrompt)
            _ = try await session.respond(to: secondTelemetryPrompt)
        }
    }

    /// The values of `generate.in_flight` after two responds that run one
    /// after the other: each counts while it runs, and then ends.
    private static let twoCallsInFlight: [Double] = [1, 0, 1, 0]

    @Test("each respond over a pooled model counts on generate.in_flight while it runs")
    func eachRespondCountsInFlight() async throws {
        let context = try await Self.captureTwoResponds()

        let inFlight = try context.metricsFactory.expectMeter(
            ExtrasTelemetry.MetricName.generateInFlight, ModelMetricDimensions.model(Self.key.ref))
        #expect(inFlight.values == Self.twoCallsInFlight)
    }

    @Test("each respond over a pooled model opens one generate span and writes one enter record")
    func eachRespondOpensOneGenerateSpan() async throws {
        let context = try await Self.captureTwoResponds()

        #expect(GenerateTelemetryExpectations.generateSpans(in: context.spans).count == Self.twoCalls)
        #expect(context.enterRecords(ofSpanNamed: ExtrasTelemetry.SpanName.generate).count == Self.twoCalls)
    }

    @Test("the first respond after a load records generate.cold true, and a later respond records false")
    func theFirstRespondIsColdAndALaterRespondIsWarm() async throws {
        let context = try await Self.captureTwoResponds()

        let spans = GenerateTelemetryExpectations.generateSpans(in: context.spans)
        try #require(spans.count == Self.twoCalls)
        GenerateTelemetryExpectations.expectCallAttributes(of: spans[0], ref: Self.key.ref, guided: false, cold: true)
        GenerateTelemetryExpectations.expectCallAttributes(of: spans[1], ref: Self.key.ref, guided: false, cold: false)
    }

    @Test("the first respond over a pooled model whose model the pool holds already records generate.cold false")
    func aFirstRespondOverAResidentModelIsWarm() async throws {
        let context = try await Self.captureGenerate {
            let model = Self.pooledModel()
            // The session keeps a hold, thus the respond acquires a resident model.
            let session = try await model.session()
            _ = try await LanguageModelSession(model: model).respond(to: Self.telemetryPrompt)
            withExtendedLifetime(session) {}
        }

        let span = try #require(GenerateTelemetryExpectations.generateSpans(in: context.spans).first)
        GenerateTelemetryExpectations.expectCallAttributes(of: span, ref: Self.key.ref, guided: false, cold: false)
    }

    @Test("a respond over a pooled model that asks for a Generable type records generate.guided true")
    func aGuidedRespondIsGuided() async throws {
        let script = StubLanguageModelScript(answer: { _ in Self.typedAnswerJSON })
        let context = try await Self.captureGenerate {
            let session = LanguageModelSession(model: Self.pooledModel(playing: script))
            _ = try await session.respond(to: Self.telemetryPrompt, generating: Answer.self)
        }

        let span = try #require(GenerateTelemetryExpectations.generateSpans(in: context.spans).first)
        GenerateTelemetryExpectations.expectCallAttributes(of: span, ref: Self.key.ref, guided: true, cold: true)
    }

    @Test("a PooledSession respond records guided false and cold false, and its typed respond records guided true")
    func aPooledSessionRecordsGuidedAndWarm() async throws {
        let script = StubLanguageModelScript(answer: { _ in Self.typedAnswerJSON })
        let context = try await Self.captureGenerate {
            let session = try await Self.pooledModel(playing: script).session()
            _ = try await session.respond(to: Self.telemetryPrompt)
            _ = try await session.respond(to: Self.secondTelemetryPrompt, generating: Answer.self)
        }

        let spans = GenerateTelemetryExpectations.generateSpans(in: context.spans)
        try #require(spans.count == Self.twoCalls)
        GenerateTelemetryExpectations.expectCallAttributes(of: spans[0], ref: Self.key.ref, guided: false, cold: false)
        GenerateTelemetryExpectations.expectCallAttributes(of: spans[1], ref: Self.key.ref, guided: true, cold: false)
    }

    @Test("each respond records one time to first token and one duration with the outcome succeeded")
    func eachRespondRecordsItsTimers() async throws {
        let context = try await Self.captureTwoResponds()

        let metrics = context.metricsFactory
        let firstTokenTimes = try GenerateTelemetryExpectations.timesToFirstToken(
            in: metrics, ref: Self.key.ref, outcome: .succeeded)
        let durations = try GenerateTelemetryExpectations.durations(in: metrics, ref: Self.key.ref, outcome: .succeeded)
        QueueMetricExpectations.expectDurations(firstTokenTimes, count: Self.twoCalls)
        QueueMetricExpectations.expectDurations(durations, count: Self.twoCalls)
        #expect(zip(firstTokenTimes, durations).allSatisfy { $0 <= $1 })
    }

    @Test("a respond whose model gives token counts records its output tokens and its tokens per second")
    func aRespondWithTokenCountsRecordsTheTokenMetrics() async throws {
        let script = StubLanguageModelScript(usages: [Self.reportedUsage])
        let context = try await Self.captureGenerate {
            _ = try await LanguageModelSession(model: Self.pooledModel(playing: script)).respond(to: Self.telemetryPrompt)
        }

        let metrics = context.metricsFactory
        let tokensPerSecond = try GenerateTelemetryExpectations.tokensPerSecond(in: metrics, ref: Self.key.ref)
        #expect(
            try GenerateTelemetryExpectations.outputTokenCounts(in: metrics, ref: Self.key.ref)
                == [Int64(Self.reportedOutputTokens)])
        #expect(tokensPerSecond.count == Self.oneCall)
        #expect(tokensPerSecond.allSatisfy { $0 > 0 })
    }

    @Test("a respond whose model gives token counts records its input and cached tokens as counters and on its span")
    func aRespondWithTokenCountsRecordsTheInputTokens() async throws {
        let script = StubLanguageModelScript(usages: [Self.reportedUsage])
        let context = try await Self.captureGenerate {
            _ = try await LanguageModelSession(model: Self.pooledModel(playing: script)).respond(to: Self.telemetryPrompt)
        }

        let metrics = context.metricsFactory
        #expect(
            try GenerateTelemetryExpectations.inputTokenCounts(in: metrics, ref: Self.key.ref)
                == [Int64(Self.reportedInputTokens)])
        #expect(
            try GenerateTelemetryExpectations.cachedTokenCounts(in: metrics, ref: Self.key.ref)
                == [Int64(Self.reportedCachedTokens)])
        let span = try #require(GenerateTelemetryExpectations.generateSpans(in: context.spans).first)
        GenerateTelemetryExpectations.expectInputTokenAttributes(
            of: span, summed: Self.reportedUsage, firstRound: Self.reportedUsage)
    }

    @Test("a PooledSession respond with a tool call sums the input and cached tokens of its rounds, and keeps its first round apart")
    func aRespondWithAToolCallSumsTheInputTokensOfItsRounds() async throws {
        let script = StubLanguageModelScript(
            usages: [Self.toolRoundUsage, Self.answerRoundUsage], toolName: SpanProbeTool.toolName)
        let context = try await Self.captureGenerate {
            let session = try await Self.pooledModel(playing: script).session(tools: [SpanProbeTool()])
            _ = try await session.respond(to: Self.telemetryPrompt)
        }

        let summed = StubTokenUsage(
            input: Self.toolRoundInputTokens + Self.answerRoundInputTokens,
            cached: Self.toolRoundCachedTokens + Self.answerRoundCachedTokens,
            output: Self.toolRoundOutputTokens + Self.answerRoundOutputTokens)
        let metrics = context.metricsFactory
        #expect(
            try GenerateTelemetryExpectations.inputTokenCounts(in: metrics, ref: Self.key.ref) == [Int64(summed.input)])
        #expect(
            try GenerateTelemetryExpectations.cachedTokenCounts(in: metrics, ref: Self.key.ref) == [Int64(summed.cached)])
        #expect(
            try GenerateTelemetryExpectations.outputTokenCounts(in: metrics, ref: Self.key.ref) == [Int64(summed.output)])
        let spans = GenerateTelemetryExpectations.generateSpans(in: context.spans)
        try #require(spans.count == Self.oneCall)
        GenerateTelemetryExpectations.expectInputTokenAttributes(
            of: spans[0], summed: summed, firstRound: Self.toolRoundUsage)
    }

    @Test("a respond whose model gives no token counts records no token metric and no token attribute")
    func aRespondWithNoTokenCountsRecordsNoTokenMetrics() async throws {
        let context = try await Self.captureTwoResponds()

        let metrics = context.metricsFactory
        #expect(throws: TestMetricsError.self) {
            try GenerateTelemetryExpectations.outputTokenCounts(in: metrics, ref: Self.key.ref)
        }
        #expect(throws: TestMetricsError.self) {
            try GenerateTelemetryExpectations.tokensPerSecond(in: metrics, ref: Self.key.ref)
        }
        #expect(throws: TestMetricsError.self) {
            try GenerateTelemetryExpectations.inputTokenCounts(in: metrics, ref: Self.key.ref)
        }
        #expect(throws: TestMetricsError.self) {
            try GenerateTelemetryExpectations.cachedTokenCounts(in: metrics, ref: Self.key.ref)
        }
        for span in GenerateTelemetryExpectations.generateSpans(in: context.spans) {
            GenerateTelemetryExpectations.expectNoInputTokenAttributes(of: span)
        }
    }

    @Test("a respond whose load fails records cold true, one duration with the outcome failed, and no time to first token")
    func aRespondWhoseLoadFailsRecordsAFailedDuration() async throws {
        let model = StubLanguageModel(script: StubLanguageModelScript())
        let loader = RecordingLoader(
            name: Self.loaderName, log: Recorder(), failingLoads: Self.oneCall, makeModel: { _ in model })
        let context = try await Self.captureGenerate {
            let session = LanguageModelSession(model: PooledModel(ref: Self.key.ref, pool: ModelPool(loader: loader)))
            await #expect(throws: FakeLoadError.self) { try await session.respond(to: Self.telemetryPrompt) }
        }

        let metrics = context.metricsFactory
        let span = try #require(GenerateTelemetryExpectations.generateSpans(in: context.spans).first)
        GenerateTelemetryExpectations.expectCallAttributes(of: span, ref: Self.key.ref, guided: false, cold: true)
        QueueMetricExpectations.expectDurations(
            try GenerateTelemetryExpectations.durations(in: metrics, ref: Self.key.ref, outcome: .failed),
            count: Self.oneCall)
        #expect(throws: TestMetricsError.self) {
            try GenerateTelemetryExpectations.timesToFirstToken(in: metrics, ref: Self.key.ref, outcome: .failed)
        }
    }

    @Test("the load span of the first respond has the generate span as its parent")
    func theLoadSpanIsAChildOfTheGenerateSpan() async throws {
        let context = try await Self.captureGenerate {
            _ = try await LanguageModelSession(model: Self.pooledModel()).respond(to: Self.telemetryPrompt)
        }

        let generateSpan = try #require(GenerateTelemetryExpectations.generateSpans(in: context.spans).first)
        let loadSpans = ModelLoadTelemetryExpectations.spans(named: ExtrasTelemetry.SpanName.modelLoad, in: context.spans)
        #expect(loadSpans.map(\.parentSpanID) == [generateSpan.spanID])
    }

    @Test("a tool span that opens inside a PooledSession respond has the generate span as its parent")
    func aToolSpanIsAChildOfTheGenerateSpan() async throws {
        let script = StubLanguageModelScript(toolName: SpanProbeTool.toolName)
        let context = try await Self.captureGenerate {
            let session = try await Self.pooledModel(playing: script).session(tools: [SpanProbeTool()])
            _ = try await session.respond(to: Self.telemetryPrompt)
        }

        let generateSpan = try #require(GenerateTelemetryExpectations.generateSpans(in: context.spans).first)
        let toolSpans = ModelLoadTelemetryExpectations.spans(named: ExtrasTelemetry.SpanName.tool, in: context.spans)
        #expect(toolSpans.map(\.parentSpanID) == [generateSpan.spanID])
    }

    @Test("the generate telemetry of both pooled paths holds no prompt and no answer, and the capture saw records")
    func theGenerateTelemetryHoldsNoContent() async throws {
        let script = StubLanguageModelScript(usages: [Self.reportedUsage, Self.reportedUsage])
        let context = try await Self.captureGenerate {
            _ = try await LanguageModelSession(model: Self.pooledModel(playing: script)).respond(to: Self.telemetryPrompt)
            _ = try await Self.pooledModel(playing: script).session().respond(to: Self.secondTelemetryPrompt)
        }

        #expect(!GenerateTelemetryExpectations.generateSpans(in: context.spans).isEmpty)
        #expect(!context.enterRecords(ofSpanNamed: ExtrasTelemetry.SpanName.generate).isEmpty)
        #expect(!context.metricRecords.isEmpty)
    }
}
