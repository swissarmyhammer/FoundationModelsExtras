@testable import FoundationModelsExtras
import Testing

/// A ``PooledLogitsModel`` sends each call to the container of its hold. A
/// model made from a name loads its model on the first call, one time only.
@Suite("Pooled logits model: a .llm hold as a log-probability source")
struct PooledLogitsModelTests {
    /// The key that the tests acquire.
    private static let key = ModelPoolKey(ref: "org/logits", role: .llm)

    /// The bytes of ``key`` for its first hold: the weights and one session.
    private static let footprintBytes: Int64 = 10

    /// The bytes of one session.
    private static let sessionBytes: Int64 = 2

    /// The prompt limit of the container of the tests.
    private static let promptLimit = 4096

    /// The container of the tests.
    private static let logits = FakeLogits(maximumPromptTokens: promptLimit)

    /// The name of the loader that ``logitsLoader(log:loadsMayEnd:)`` makes.
    private static let loaderName = "A"

    /// The log entry of one load of ``key`` by the loader that
    /// ``logitsLoader(log:loadsMayEnd:)`` makes.
    private static let loadEntry = "load \(key.ref.stringValue) by \(loaderName)"

    /// Acquires ``key`` from `pool`.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - loader: The loader.
    /// - Returns: The hold.
    /// - Throws: What the load throws.
    private static func acquire(from pool: ModelPool, with loader: any PooledModelLoader) async throws -> ModelHold {
        try await pool.acquire(key, footprintBytes: footprintBytes, sessionBytes: sessionBytes, loader: loader)
    }

    /// Makes a model that keeps a hold of ``logits``.
    ///
    /// - Returns: The model.
    /// - Throws: What the load or the cast throws.
    private static func heldModel() async throws -> PooledLogitsModel {
        try PooledLogitsModel(hold: await acquire(from: ModelPool(), with: FixedLoader(container: logits)))
    }

    /// Makes a loader that writes each load to `log`, and gives ``logits``.
    ///
    /// - Parameters:
    ///   - log: The log of the loads, the measures and the evictions.
    ///   - loadsMayEnd: A load ends only after this stream finishes. The
    ///     default stream is finished, so a load ends at once.
    /// - Returns: The loader.
    private static func logitsLoader(
        log: Recorder<String>, loadsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() }
    ) -> RecordingLoader {
        RecordingLoader(name: loaderName, log: log, loadsMayEnd: loadsMayEnd, makeModel: { _ in logits })
    }

    /// The loads in `log`.
    ///
    /// - Parameter log: The log of a loader that
    ///   ``logitsLoader(log:loadsMayEnd:)`` made.
    /// - Returns: Each load entry, in order.
    private static func loads(in log: Recorder<String>) -> [String] {
        log.values.filter { $0.hasPrefix("load ") }
    }

    @Test("tokenize gives the tokens of the container")
    func tokenizeForwardsToTheContainer() async throws {
        let model = try await Self.heldModel()

        #expect(try await model.tokenize("ab") == [97, 98])
    }

    @Test("renderChatTemplate gives the text of the container")
    func renderChatTemplateForwardsToTheContainer() async throws {
        let model = try await Self.heldModel()

        let text = try await model.renderChatTemplate([["role": "user", "content": "hi"]], reasoning: false)

        #expect(text == "user: hi\nreasoning: false")
    }

    @Test("logProbabilities gives the rows of the container")
    func logProbabilitiesForwardsToTheContainer() async throws {
        let model = try await Self.heldModel()

        let rows = try await model.logProbabilities(of: [5, 7], after: [[1], [1, 2]])

        #expect(rows == [[4, 6], [3, 5]])
    }

    @Test("maximumPromptTokens gives the limit of the container")
    func maximumPromptTokensForwardsToTheContainer() async throws {
        let model = try await Self.heldModel()

        #expect(model.maximumPromptTokens == Self.promptLimit)
    }

    @Test("a model made from a hold reports the ref of the key of the hold")
    func aHeldModelReportsTheRefOfItsHold() async throws {
        let model = try await Self.heldModel()

        #expect(model.ref == Self.key.ref)
    }

    @Test("a model made from a name reports that name, and loads nothing")
    func aNamedModelReportsItsRefAndLoadsNothing() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.logitsLoader(log: log))

        let model = PooledLogitsModel(ref: Self.key.ref, pool: pool)
        // An admission job ends after each load that is in the admission queue now.
        try await pool.admit { _ in }

        #expect(model.ref == Self.key.ref)
        #expect(log.values.isEmpty)
    }

    @Test("a model made from a name has no prompt limit before its first call, and the limit of the container after it")
    func aNamedModelGivesThePromptLimitAfterTheLoad() async throws {
        let pool = ModelPool(loader: Self.logitsLoader(log: Recorder()))
        let model = PooledLogitsModel(ref: Self.key.ref, pool: pool)

        let limitBeforeTheLoad = model.maximumPromptTokens
        _ = try await model.tokenize("a")

        #expect(limitBeforeTheLoad == nil)
        #expect(model.maximumPromptTokens == Self.promptLimit)
    }

    @Test("the first call of a model made from a name loads the model with the loader of the pool")
    func theFirstCallLoadsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.logitsLoader(log: log))
        let model = PooledLogitsModel(ref: Self.key.ref, pool: pool)

        let rows = try await model.logProbabilities(of: [3], after: [[1]])

        #expect(rows == [[2]])
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("a hold whose container is not a PooledLogits makes init(hold:) throw notLogitsCapable")
    func aHoldThatIsNotLogitsCapableThrows() async throws {
        let hold = try await Self.acquire(from: ModelPool(), with: RecordingLoader(name: Self.loaderName, log: Recorder()))

        #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.key.ref)) { try PooledLogitsModel(hold: hold) }
    }

    @Test("the message of notLogitsCapable names PooledLogits")
    func theMessageOfNotLogitsCapableNamesTheProtocol() {
        let error = PooledLogitsModelError.notLogitsCapable(Self.key.ref)

        #expect(error.errorDescription?.contains("PooledLogits") == true)
    }

    @Test("the first call of a model made from a name throws notLogitsCapable when the container is not a PooledLogits")
    func aNamedModelThatIsNotLogitsCapableThrows() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let model = PooledLogitsModel(ref: Self.key.ref, pool: pool)

        await #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.key.ref)) {
            try await model.tokenize("a")
        }
    }

    @Test("a model made from a name keeps no hold when its container is not a PooledLogits")
    func aNamedModelThatIsNotLogitsCapableKeepsNoHold() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let model = PooledLogitsModel(ref: Self.key.ref, pool: pool)

        _ = try? await model.tokenize("a")
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(!pool.isResident(Self.key))
    }

    @Test("two concurrent first calls of one model make one load")
    func concurrentFirstCallsMakeOneLoad() async throws {
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let pool = ModelPool(loader: Self.logitsLoader(log: log, loadsMayEnd: loadsMayEnd))
        let model = PooledLogitsModel(ref: Self.key.ref, pool: pool)

        defer { endLoads.finish() }
        let first = Task { try await model.tokenize("a") }
        let second = Task { try await model.tokenize("b") }
        await log.waitUntil(holds: Self.loadEntry, orUntilEndOf: first)
        try #require(Self.loads(in: log) == [Self.loadEntry])
        endLoads.finish()
        let tokens = try await [first.value, second.value]

        #expect(tokens == [[97], [98]])
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("the model stays resident while a copy exists, and the pool releases the hold after the last copy goes")
    func theLastCopyReleasesTheHold() async throws {
        let pool = ModelPool(loader: Self.logitsLoader(log: Recorder()))
        var model: PooledLogitsModel? = PooledLogitsModel(ref: Self.key.ref, pool: pool)
        var copy = model

        _ = try await model?.tokenize("a")
        model = nil
        try await pool.waitForTheEarlierAdmissionJobs()
        let residentWhileACopyExists = pool.isResident(Self.key)
        let copyTokens = try await copy?.tokenize("b")
        copy = nil
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(residentWhileACopyExists)
        #expect(copyTokens == [98])
        #expect(!pool.isResident(Self.key))
    }

    @Test("the README example: a model from a name loads the model on its first call")
    func readmeLogitsExample() async throws {
        let pool = ModelPool(loader: FixedLoader(container: Self.logits))

        // README example: begin
        // Loads nothing now. The first call loads the model into the pool.
        let model = PooledLogitsModel(ref: "mlx-community/Qwen3-4B-4bit", pool: pool)
        let candidates = try await model.tokenize("AB")
        let prompt = try await model.tokenize("Answer A or B: ")
        let rows = try await model.logProbabilities(of: candidates, after: [prompt])
        // README example: end

        #expect(rows.map(\.count) == [candidates.count])
    }
}
