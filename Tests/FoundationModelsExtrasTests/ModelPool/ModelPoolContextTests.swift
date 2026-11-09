import Foundation
import Synchronization
import Testing

@testable import FoundationModelsExtras

/// The context size of a ``ModelPoolKey``: the loader normalizes it with
/// ``PooledModelLoader/poolKey(for:)``, and a resident model of a larger
/// context gives the hold of a smaller one.
@Suite("Model pool context: a context size per load")
struct ModelPoolContextTests {
    /// The model of each test.
    private static let ref: ModelRef = "org/a"

    @Test("a loader that ignores the context keeps one key per model")
    func defaultLoaderDropsTheContext() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: log))

        let first = try await pool.acquire(Self.key(8192))
        let second = try await pool.acquire(Self.key(32768))

        #expect(log.values == ["load org/a by A", "measure org/a"])
        #expect(first.key == ModelPoolKey(ref: Self.ref, role: .llm))
        #expect(second.key == first.key)
    }

    @Test("a smaller context reuses a resident load of a larger context")
    func smallerReusesLarger() async throws {
        let loader = ContextLoader()
        let pool = ModelPool(loader: loader)

        let large = try await pool.acquire(Self.key(32768))
        let small = try await pool.acquire(Self.key(8192))

        #expect(loader.loads.values == [32768])
        #expect(small.key.contextSize == 32768)
        #expect((small.container as? StubLanguageModel)?.script === (large.container as? StubLanguageModel)?.script)
    }

    @Test("a larger context loads again, and leaves the smaller load as it is")
    func largerLoadsAgain() async throws {
        let loader = ContextLoader()
        let pool = ModelPool(loader: loader)

        let small = try await pool.acquire(Self.key(8192))
        let large = try await pool.acquire(Self.key(32768))

        #expect(loader.loads.values == [8192, 32768])
        #expect(small.key.contextSize == 8192)
        #expect(large.key.contextSize == 32768)
        #expect(pool.isResident(Self.key(8192)))
        #expect(pool.isResident(Self.key(32768)))
    }

    @Test("a request takes the smallest resident context that fits it")
    func smallestFittingContext() async throws {
        let loader = ContextLoader()
        let pool = ModelPool(loader: loader)
        let small = try await pool.acquire(Self.key(8192))
        let large = try await pool.acquire(Self.key(65536))

        let middle = try await pool.acquire(Self.key(16384))
        let least = try await pool.acquire(Self.key(4096))

        #expect(loader.loads.values == [8192, 65536])
        #expect(middle.key == large.key)
        #expect(least.key == small.key)
    }

    @Test("the footprint measure gets the key with its context")
    func measureGetsTheContext() async throws {
        let loader = ContextLoader()
        let pool = ModelPool(loader: loader)

        let hold = try await pool.acquire(Self.key(16384))

        #expect(loader.measures.values == [16384])
        #expect(pool.footprint.resident[hold.key] == 16384)
    }

    @Test("an acquire through the admission reuses a larger context too")
    func admissionReusesLarger() async throws {
        let loader = ContextLoader()
        let pool = ModelPool(loader: loader)
        let large = try await pool.acquire(Self.key(32768))

        let small = try await pool.admit { admission in try await admission.acquire(Self.key(8192)) }

        #expect(loader.loads.values == [32768])
        #expect(small.key == large.key)
    }

    @Test("the release of a reused hold releases the resident model")
    func releaseOfAReusedHold() async throws {
        let loader = ContextLoader()
        let pool = ModelPool(loader: loader)
        var large: ModelHold? = try await pool.acquire(Self.key(32768))
        var small: ModelHold? = try await pool.acquire(Self.key(8192))
        #expect(large != nil && small != nil)

        large = nil
        small = nil
        _ = try await pool.admit { _ in }

        #expect(!pool.isResident(Self.key(32768)))
        #expect(loader.evictions.values == [32768])
    }

    @Test("a pooled model with a context reads the key that the pool loaded")
    func pooledModelReadsTheLoadedKey() async throws {
        let loader = ContextLoader()
        let pool = ModelPool(loader: loader)
        let large = try await pool.acquire(Self.key(32768))

        let model = PooledModel(ref: Self.ref, pool: pool, contextSize: 8192)
        let loaded = try await model.loadedKey()

        #expect(loaded == large.key)
        #expect(loader.loads.values == [32768])
    }

    // MARK: Helpers

    /// The key of ``ref`` as an LLM at `contextSize`.
    private static func key(_ contextSize: Int?) -> ModelPoolKey {
        ModelPoolKey(ref: ref, role: .llm, contextSize: contextSize)
    }

    /// A loader that keeps the context of each key, as the GGUF loader does.
    /// Each load gives a new ``StubLanguageModel``, thus a pooled model takes
    /// it. The loader records the context of each load, each measure and each
    /// eviction, and measures each model as its context size.
    private final class ContextLoader: PooledModelLoader {
        /// The context of each load.
        let loads = Recorder<Int?>()

        /// The context of each measure.
        let measures = Recorder<Int?>()

        /// The context of each eviction.
        let evictions = Recorder<Int?>()

        /// The context of the model of each script.
        private let contexts = Mutex<[ObjectIdentifier: Int?]>([:])

        func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey { key }

        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            loads.append(key.contextSize)
            let model = StubLanguageModel(script: StubLanguageModelScript())
            contexts.withLock { $0[ObjectIdentifier(model.script)] = key.contextSize }
            return model
        }

        func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
            measures.append(key.contextSize)
            return Int64(key.contextSize ?? 0)
        }

        func evict(_ container: any Sendable) async {
            guard let model = container as? StubLanguageModel else { return }
            evictions.append(contexts.withLock { $0[ObjectIdentifier(model.script)] ?? nil })
        }
    }
}
