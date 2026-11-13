@testable import FoundationModelsExtras
import Testing

/// A ``PooledDecisionsModel`` sends each call to the container of its hold.
/// A model made from a name loads its model on the first call, one time only.
/// A container with no decision type makes the first call throw.
@Suite("Pooled decisions model: a .llm hold that answers decision questions")
struct PooledDecisionsModelTests {
    /// The key that the tests acquire.
    private static let key = ModelPoolKey(ref: "org/decisions", role: .llm)

    /// The bytes of ``key`` for its first hold: the weights and one session.
    private static let footprintBytes: Int64 = 10

    /// The bytes of one session.
    private static let sessionBytes: Int64 = 2

    /// The decision type name of the container of the tests.
    private static let typeName = "triage"

    /// The container of the tests, which has a decision type.
    private static let decisions = FakeDecisions(decisionTypeName: typeName)

    /// A container that conforms, but has no decision type.
    private static let untypedDecisions = FakeDecisions(decisionTypeName: nil)

    /// The name of the loader that ``decisionsLoader(log:container:loadsMayEnd:)`` makes.
    private static let loaderName = "A"

    /// The log entry of one load of ``key`` by the loader that
    /// ``decisionsLoader(log:container:loadsMayEnd:)`` makes.
    private static let loadEntry = "load \(key.ref.stringValue) by \(loaderName)"

    /// The state of the questions of the tests.
    private static let state = PooledDecisionState.json(#"{"b":1,"a":2}"#)

    /// A `score` question with three levels.
    private static let scoreQuestion = PooledDecisionQuestion(
        id: "urgency",
        type: .score,
        instructions: "How urgent is the ticket?",
        options: [
            PooledDecisionOption(key: "0", description: "low"),
            PooledDecisionOption(key: "1", description: "medium"),
            PooledDecisionOption(key: "2", description: "high"),
        ]
    )

    /// A `noul` question with no descriptions.
    private static let noulQuestion = PooledDecisionQuestion(
        id: "spam",
        type: .noul,
        instructions: "Is the ticket spam?",
        options: [PooledDecisionOption(key: "true"), PooledDecisionOption(key: "false")]
    )

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

    /// Makes a model that keeps a hold of `container`.
    ///
    /// - Parameter container: The container of the hold. The default is ``decisions``.
    /// - Returns: The model.
    /// - Throws: What the load or the cast throws.
    private static func heldModel(of container: FakeDecisions = decisions) async throws -> PooledDecisionsModel {
        try PooledDecisionsModel(hold: await acquire(from: ModelPool(), with: FixedLoader(container: container)))
    }

    /// Makes a loader that writes each load to `log`, and gives `container`.
    ///
    /// - Parameters:
    ///   - log: The log of the loads, the measures and the evictions.
    ///   - container: The container that each load gives. The default is ``decisions``.
    ///   - loadsMayEnd: A load ends only after this stream finishes. The
    ///     default stream is finished, so a load ends at once.
    /// - Returns: The loader.
    private static func decisionsLoader(
        log: Recorder<String>,
        container: FakeDecisions = decisions,
        loadsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() }
    ) -> RecordingLoader {
        RecordingLoader(name: loaderName, log: log, loadsMayEnd: loadsMayEnd, makeModel: { _ in container })
    }

    /// Makes a model from the name of ``key``, with a pool whose loader gives `container`.
    ///
    /// - Parameter container: The container that each load gives.
    /// - Returns: The pool and the model.
    private static func namedModel(of container: FakeDecisions) -> (pool: ModelPool, model: PooledDecisionsModel) {
        let pool = ModelPool(loader: decisionsLoader(log: Recorder(), container: container))
        return (pool, PooledDecisionsModel(ref: key.ref, pool: pool))
    }

    /// The loads in `log`.
    ///
    /// - Parameter log: The log of a loader that
    ///   ``decisionsLoader(log:container:loadsMayEnd:)`` made.
    /// - Returns: Each load entry, in order.
    private static func loads(in log: Recorder<String>) -> [String] {
        log.values.filter { $0.hasPrefix("load ") }
    }

    @Test("decisionType gives the decision type of the container")
    func decisionTypeForwardsToTheContainer() async throws {
        let model = try await Self.heldModel()

        #expect(try await model.decisionType() == Self.typeName)
    }

    @Test("decide gives the answers of the container, in question order")
    func decideForwardsToTheContainer() async throws {
        let model = try await Self.heldModel()

        let answers = try await model.decide(state: Self.state, questions: [Self.scoreQuestion, Self.noulQuestion])

        #expect(answers == [
            PooledDecisionAnswer(id: "urgency", probabilities: [1, 2, 3], expectedValue: 3),
            PooledDecisionAnswer(id: "spam", probabilities: [1, 2], expectedValue: nil),
        ])
    }

    @Test("a model made from a hold reports the ref of the key of the hold")
    func aHeldModelReportsTheRefOfItsHold() async throws {
        let model = try await Self.heldModel()

        #expect(model.ref == Self.key.ref)
    }

    @Test("a model made from a name reports that name, and loads nothing")
    func aNamedModelReportsItsRefAndLoadsNothing() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.decisionsLoader(log: log))

        let model = PooledDecisionsModel(ref: Self.key.ref, pool: pool)
        // An admission job ends after each load that is in the admission queue now.
        try await pool.admit { _ in }

        #expect(model.ref == Self.key.ref)
        #expect(log.values.isEmpty)
    }

    @Test("the first call of a model made from a name loads the model with the loader of the pool")
    func theFirstCallLoadsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.decisionsLoader(log: log))
        let model = PooledDecisionsModel(ref: Self.key.ref, pool: pool)

        let answers = try await model.decide(state: .text("a ticket"), questions: [Self.noulQuestion])

        #expect(answers == [PooledDecisionAnswer(id: "spam", probabilities: [1, 2], expectedValue: nil)])
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("a hold whose container is not a PooledDecisions makes init(hold:) throw notDecisionCapable")
    func aHoldThatIsNotDecisionCapableThrows() async throws {
        let hold = try await Self.acquire(from: ModelPool(), with: RecordingLoader(name: Self.loaderName, log: Recorder()))

        #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try PooledDecisionsModel(hold: hold)
        }
    }

    @Test("the message of notDecisionCapable names PooledDecisions")
    func theMessageOfNotDecisionCapableNamesTheProtocol() {
        let error = PooledDecisionsModelError.notDecisionCapable(Self.key.ref)

        #expect(error.errorDescription?.contains("PooledDecisions") == true)
    }

    @Test("the first call of a model made from a name throws notDecisionCapable when the container is not a PooledDecisions")
    func aNamedModelThatIsNotDecisionCapableThrows() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let model = PooledDecisionsModel(ref: Self.key.ref, pool: pool)

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try await model.decisionType()
        }
    }

    @Test("a model made from a name keeps no hold when its container is not a PooledDecisions")
    func aNamedModelThatIsNotDecisionCapableKeepsNoHold() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let model = PooledDecisionsModel(ref: Self.key.ref, pool: pool)

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try await model.decisionType()
        }
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(!pool.isResident(Self.key))
    }

    @Test("the first decide of a model made from a hold throws notDecisionCapable when the container has no decision type")
    func aHeldUntypedModelThrowsOnDecide() async throws {
        let model = try await Self.heldModel(of: Self.untypedDecisions)

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try await model.decide(state: Self.state, questions: [Self.noulQuestion])
        }
    }

    @Test("the first decisionType of a model made from a hold throws notDecisionCapable when the container has no decision type")
    func aHeldUntypedModelThrowsOnDecisionType() async throws {
        let model = try await Self.heldModel(of: Self.untypedDecisions)

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try await model.decisionType()
        }
    }

    @Test("the first decide of a model made from a name throws notDecisionCapable when the container has no decision type")
    func aNamedUntypedModelThrowsOnDecide() async throws {
        let (_, model) = Self.namedModel(of: Self.untypedDecisions)

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try await model.decide(state: Self.state, questions: [Self.noulQuestion])
        }
    }

    @Test("the first decisionType of a model made from a name throws notDecisionCapable when the container has no decision type")
    func aNamedUntypedModelThrowsOnDecisionType() async throws {
        let (_, model) = Self.namedModel(of: Self.untypedDecisions)

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try await model.decisionType()
        }
    }

    @Test("a model made from a name keeps no hold when its container has no decision type")
    func aNamedUntypedModelKeepsNoHold() async throws {
        let (pool, model) = Self.namedModel(of: Self.untypedDecisions)

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(Self.key.ref)) {
            try await model.decisionType()
        }
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(!pool.isResident(Self.key))
    }

    @Test("two concurrent first calls of one model make one load")
    func concurrentFirstCallsMakeOneLoad() async throws {
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let pool = ModelPool(loader: Self.decisionsLoader(log: log, loadsMayEnd: loadsMayEnd))
        let model = PooledDecisionsModel(ref: Self.key.ref, pool: pool)

        defer { endLoads.finish() }
        let first = Task { try await model.decide(state: Self.state, questions: [Self.noulQuestion]) }
        let second = Task { try await model.decisionType() }
        await log.waitUntil(holds: Self.loadEntry, orUntilEndOf: first)
        try #require(Self.loads(in: log) == [Self.loadEntry])
        endLoads.finish()
        let answers = try await first.value
        let typeName = try await second.value

        #expect(answers == [PooledDecisionAnswer(id: "spam", probabilities: [1, 2], expectedValue: nil)])
        #expect(typeName == Self.typeName)
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("the model stays resident while a copy exists, and the pool releases the hold after the last copy goes")
    func theLastCopyReleasesTheHold() async throws {
        let pool = ModelPool(loader: Self.decisionsLoader(log: Recorder()))
        var model: PooledDecisionsModel? = PooledDecisionsModel(ref: Self.key.ref, pool: pool)
        var copy = model

        _ = try await model?.decisionType()
        model = nil
        try await pool.waitForTheEarlierAdmissionJobs()
        let residentWhileACopyExists = pool.isResident(Self.key)
        let copyTypeName = try await copy?.decisionType()
        copy = nil
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(residentWhileACopyExists)
        #expect(copyTypeName == Self.typeName)
        #expect(!pool.isResident(Self.key))
    }

    @Test("the README example: a model from a name loads the model on its first call")
    func readmeDecisionsExample() async throws {
        let pool = ModelPool(loader: FixedLoader(container: Self.decisions))

        // README example: begin
        // Loads nothing now. The first call loads the model into the pool.
        let model = PooledDecisionsModel(ref: "org/decision-model-GGUF", pool: pool)
        let question = PooledDecisionQuestion(
            id: "spam",
            type: .noul,
            instructions: "Is the ticket spam?",
            options: [PooledDecisionOption(key: "true"), PooledDecisionOption(key: "false")]
        )
        let answers = try await model.decide(state: .text("Win a free phone!"), questions: [question])
        // README example: end

        #expect(answers.map(\.probabilities.count) == [question.options.count])
    }
}
