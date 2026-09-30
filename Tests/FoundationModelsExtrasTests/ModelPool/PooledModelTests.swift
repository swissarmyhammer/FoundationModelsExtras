import FoundationModels
@testable import FoundationModelsExtras
import Testing

/// The typed answer of the typed respond test and of the README example.
@Generable
private struct Answer {
    /// A number.
    let number: Int
}

/// A ``PooledModel`` loads nothing when you make it. Its first session loads
/// the LLM into the pool. Each session keeps a hold of the model, and each
/// respond call is one job in the queue of the model.
@Suite("Pooled model: sessions of an LLM by name, with one load and one queue")
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

    /// The third prompt of a test.
    private static let thirdPrompt = "three"

    /// The number of calls that wait in the queue behind the first call.
    private static let oneWaitingCall = 1

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
        /// The queue of the model.
        let queue: GenerationQueue
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
        let queue = try await pool.acquire(key).queue
        let firstCall = Task { try await session.respond(to: firstPrompt) }
        try #require(await BoundedWait.conditionReached("the first call runs") { log.values == ["begin \(firstPrompt)"] })
        return BlockedCall(
            model: model, session: session, queue: queue, log: log, endFirstCall: endFirstCall, firstCall: firstCall)
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

        async let firstSession = first.session()
        async let secondSession = second.session()
        try #require(await BoundedWait.conditionReached("the load runs") { Self.loads(in: log) == [Self.loadEntry] })
        endLoads.finish()
        let sessions = try await [firstSession, secondSession]

        #expect(sessions.map(\.model) == [Self.key.ref, Self.key.ref])
        #expect(pool.residentModelCount == 1)
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("two sessions of one model never run respond at the same time, and the calls run in FIFO order")
    func twoSessionsRespondOneAtATime() async throws {
        let blocked = try await Self.startBlockedCall()
        let secondSession = try await blocked.model.session()

        let secondCall = Task { try await secondSession.respond(to: Self.secondPrompt) }
        try await blocked.queue.waitForWaitingJobs(count: Self.oneWaitingCall)
        blocked.endFirstCall.finish()
        let answers = try await [blocked.firstCall.value, secondCall.value]

        #expect(answers == [Self.firstPrompt, Self.secondPrompt])
        #expect(blocked.log.values == [
            "begin \(Self.firstPrompt)", "end \(Self.firstPrompt)", "begin \(Self.secondPrompt)", "end \(Self.secondPrompt)",
        ])
    }

    @Test("a fork continues the transcript of its parent, and the parent does not see the turns of the fork")
    func aForkContinuesTheTranscript() async throws {
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: Recorder()))
        let session = try await PooledModel(ref: Self.key.ref, pool: pool).session()

        _ = try await session.respond(to: Self.firstPrompt)
        let child = try await session.fork()
        let childAnswer = try await child.respond(to: Self.secondPrompt)
        let parentAnswer = try await session.respond(to: Self.thirdPrompt)

        #expect(child.model == Self.key.ref)
        #expect(childAnswer == "\(Self.firstPrompt) \(Self.secondPrompt)")
        #expect(parentAnswer == "\(Self.firstPrompt) \(Self.thirdPrompt)")
    }

    @Test("a fork made while a respond of its parent runs waits in the queue, and continues after that turn")
    func aForkWaitsForTheRunningRespond() async throws {
        let blocked = try await Self.startBlockedCall()

        let fork = Task { try await blocked.session.fork() }
        try await blocked.queue.waitForWaitingJobs(count: Self.oneWaitingCall)
        blocked.endFirstCall.finish()
        _ = try await blocked.firstCall.value
        let childAnswer = try await fork.value.respond(to: Self.secondPrompt)

        #expect(childAnswer == "\(Self.firstPrompt) \(Self.secondPrompt)")
    }

    @Test("the model stays resident while a session or its fork exists, and is evicted after the last one goes")
    func theLastSessionEvictsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.stubLoader(script: StubLanguageModelScript(), log: log))
        var session: PooledSession? = try await PooledModel(ref: Self.key.ref, pool: pool).session()
        var child: PooledSession? = try await session?.fork()

        session = nil
        // An admission job ends after each eviction job that is in the admission queue now.
        try await pool.admit { _ in }
        let residentWhileTheForkExists = pool.isResident(Self.key)
        let childAnswer = try await child?.respond(to: Self.firstPrompt)
        child = nil

        #expect(residentWhileTheForkExists)
        #expect(childAnswer == Self.firstPrompt)
        #expect(Self.loads(in: log) == [Self.loadEntry])
        #expect(await BoundedWait.conditionReached("the eviction after the last session goes") { !pool.isResident(Self.key) })
    }

    @Test("respond(to:generating:) decodes the answer of the model as a Generable type")
    func aTypedRespondDecodesTheAnswer() async throws {
        let script = StubLanguageModelScript(answer: { _ in Self.typedAnswerJSON })
        let pool = ModelPool(loader: Self.stubLoader(script: script, log: Recorder()))
        let session = try await PooledModel(ref: Self.key.ref, pool: pool).session()

        let answer = try await session.respond(to: Self.firstPrompt, generating: Answer.self)

        #expect(answer.number == Self.typedAnswerNumber)
    }

    @Test("the README example: a session answers with text and with a Generable type, and a fork continues it")
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
        let child = try await session.fork()   // continues the transcript, with its own hold
        // README example: end

        #expect(text == Self.typedAnswerJSON)
        #expect(typed.number == Self.typedAnswerNumber)
        #expect(child.model == session.model)
        #expect(Self.loads(in: log) == ["load \(session.model.stringValue) by \(Self.loaderName)"])
    }

    @Test("a session on a container that is not a LanguageModel gives a clear error, and keeps no hold")
    func aContainerThatIsNotALanguageModelThrows() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let model = PooledModel(ref: Self.key.ref, pool: pool)
        let expected = PooledSessionError.notALanguageModel(key: Self.key, containerType: "FakeModel")

        await #expect(throws: expected) { try await model.session() }
        #expect(expected.errorDescription?.contains("LanguageModel") == true)
        #expect(await BoundedWait.conditionReached("the eviction of the model") { !pool.isResident(Self.key) })
    }
}
