import FoundationModelsExtras
import Testing

/// One model that a suite loads one time for all of its tests.
struct SharedModel: Sendable {
    /// The model.
    let key: ModelPoolKey

    /// The bytes that the pool counts for the weights and one session of the
    /// model.
    let footprint: Int64

    /// The loader of the model.
    let loader: any PooledModelLoader

    /// Makes the declaration of one shared model.
    ///
    /// - Parameters:
    ///   - key: One of the models of ``IntegrationModels``.
    ///   - footprint: The bytes that the pool counts for the weights and one
    ///     session of the model. The default is
    ///     ``IntegrationModels/footprintBytes``.
    ///   - loader: The loader of the model. The default is the built-in
    ///     `MLXModelLoader` of the core.
    init(
        _ key: ModelPoolKey, footprint: Int64 = IntegrationModels.footprintBytes,
        loader: any PooledModelLoader = MLXModelLoader()
    ) {
        self.key = key
        self.footprint = footprint
        self.loader = loader
    }
}

/// The models that the ``SharedLoadsTrait`` of the running suite loaded, and
/// the pool that holds them.
///
/// The trait holds one hold of each model while the tests of its suite run.
/// A test uses the container of a hold, or makes more holds in ``pool``, and
/// keeps nothing after it returns. A generation that a test starts on a
/// shared hold ends before the test returns, also when the test throws. Thus
/// the next test finds an idle model.
struct SharedModels: Sendable {
    /// The shared models of the running suite, or `nil` outside a suite with
    /// the trait.
    @TaskLocal static var current: SharedModels?

    /// The pool that holds the shared models.
    let pool: ModelPool

    /// The hold of each shared model, by its key.
    private let holds: [ModelPoolKey: ModelHold]

    /// The shared models of the running suite.
    ///
    /// - Returns: The shared models.
    /// - Throws: A failed expectation when the suite has no ``SharedLoadsTrait``.
    static func required() throws -> SharedModels {
        try #require(current, "the suite of this test does not load shared models")
    }

    /// The hold of the shared model of `key`.
    ///
    /// - Parameter key: A model that the trait of the suite declares.
    /// - Returns: The hold.
    /// - Throws: A failed expectation when the trait does not declare `key`.
    func hold(of key: ModelPoolKey) throws -> ModelHold {
        try #require(holds[key], "the suite of this test does not load \(key.ref.stringValue)")
    }

    /// Loads `models` in a new pool, one after the other, and runs `body`
    /// with them. The holds go when `body` returns or throws. Then this
    /// function waits for the eviction of each model, on the two paths, and
    /// then gives the error of `body`.
    ///
    /// - Parameters:
    ///   - models: The models to load.
    ///   - body: The work with the models.
    /// - Throws: The error of a load or of `body`, or `CancellationError`
    ///   when the task is cancelled during a wait for an eviction.
    static func withLoads(
        _ models: [SharedModel], _ body: @Sendable (SharedModels) async throws -> Void
    ) async throws {
        let pool = ModelPool()
        let outcome: Result<Void, any Error>
        do {
            try await body(SharedModels(pool: pool, holds: try await loadEach(models, in: pool)))
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        for model in models {
            try await IntegrationModels.waitForEviction(of: model.key, in: pool)
        }
        try outcome.get()
    }

    /// Loads each of `models` in `pool`, one after the other.
    ///
    /// - Parameters:
    ///   - models: The models to load.
    ///   - pool: The pool of the suite.
    /// - Returns: The hold of each model, by its key.
    /// - Throws: The error of a load. The holds of the earlier loads then go.
    private static func loadEach(
        _ models: [SharedModel], in pool: ModelPool
    ) async throws -> [ModelPoolKey: ModelHold] {
        let (stream, continuation) = AsyncStream.makeStream(of: SharedModel.self)
        for model in models {
            continuation.yield(model)
        }
        continuation.finish()
        return try await stream.reduce(into: [:]) { holds, model in
            holds[model.key] = try await IntegrationModels.acquire(
                key: model.key, in: pool, loader: model.loader, footprint: model.footprint)
        }
    }
}

/// A suite trait that loads the models of the suite one time, before its
/// first test, and releases them after its last test.
///
/// Each test of the suite reads the models through ``SharedModels/current``.
/// After the last test, the holds go and the trait waits for the eviction of
/// each model, also when a test throws. Thus the next suite starts with no
/// model of this suite in memory. The trait reads no clock and sets no time
/// limit: each wait ends on a load, an admission job or a footprint.
struct SharedLoadsTrait: SuiteTrait, TestScoping {
    /// The models of the suite.
    let models: [SharedModel]

    /// The trait applies to the suite one time, not to each test.
    var isRecursive: Bool { false }

    /// Loads the models, runs the tests of the suite with them, and then
    /// releases them and waits for their eviction.
    ///
    /// - Parameters:
    ///   - test: The suite.
    ///   - testCase: `nil` for a suite.
    ///   - function: Runs the tests of the suite.
    /// - Throws: A failed expectation when the machine has no Metal device,
    ///   the error of a load, or what `function` throws.
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try ModelAvailability.requireMetalDevice()
        try await SharedModels.withLoads(models) { shared in
            try await SharedModels.$current.withValue(shared) {
                try await function()
            }
        }
    }
}

extension Trait where Self == SharedLoadsTrait {
    /// Loads `models` one time for all the tests of the suite.
    ///
    /// - Parameter models: The models of the suite.
    /// - Returns: The trait.
    static func sharedLoads(_ models: SharedModel...) -> Self {
        SharedLoadsTrait(models: models)
    }
}
