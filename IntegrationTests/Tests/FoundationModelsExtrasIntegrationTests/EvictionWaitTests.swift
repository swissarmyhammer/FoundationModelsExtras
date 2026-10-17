import FoundationModelsExtras
import TelemetryTestSupport
import Testing

/// The model of the eviction-wait test. No loader downloads it: the fake
/// loader of the test gives a container for each key.
private let fakeKey = ModelPoolKey(ref: "fake/gated-eviction", role: .llm)

/// The bytes that the pool counts for the fake model.
private let fakeFootprintBytes: Int64 = 1

/// The depth of the admission queue when the wait parks behind the eviction
/// job: the eviction job runs, and one more job waits.
private let depthWithTheWaitBehindTheEviction: Double = 2

/// The test of the helper that each real-model test calls after its last
/// release. A fake loader holds the eviction at a gate, thus the test needs no
/// real model and no MLX.
@Suite("The eviction wait of the real-model tests")
struct EvictionWaitTests {
    @Test("waitForEviction returns only after the evict call of the loader returned")
    func waitForEvictionReturnsAfterTheEvictCall() async throws {
        let gate = EvictionGate()
        let pool = ModelPool()

        let evictionEndedAtReturn = try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.acquireAndRelease(in: pool, loader: GatedEvictionLoader(gate: gate))
            // The eviction job runs, and its evict call waits at the gate.
            await gate.started.waitUntilOpen()
            let waiting = Task { try await Self.evictionEndedAtReturn(of: gate, in: pool) }
            // A correct wait parks in the admission queue behind the gated
            // eviction job. A wait that does not wait returns first.
            await Waits.untilFirstEnds(
                { await context.wait { QueueDepth.admission(in: $0) == depthWithTheWaitBehindTheEviction } },
                { _ = await waiting.result })
            gate.open()
            return try await waiting.value
        }

        #expect(evictionEndedAtReturn)
    }

    /// Acquires the fake model with `loader`, and releases the hold on return.
    /// The release puts the eviction job in the admission queue.
    ///
    /// - Parameters:
    ///   - pool: The pool of the test.
    ///   - loader: The fake loader.
    /// - Throws: What the acquire throws.
    private static func acquireAndRelease(in pool: ModelPool, loader: GatedEvictionLoader) async throws {
        let hold = try await pool.acquire(fakeKey, footprintBytes: fakeFootprintBytes, sessionBytes: 0, loader: loader)
        withExtendedLifetime(hold) {}
    }

    /// Waits for the eviction of the fake model with the helper of the
    /// real-model tests.
    ///
    /// - Parameters:
    ///   - gate: The gate of the fake eviction.
    ///   - pool: The pool of the test.
    /// - Returns: Whether the evict call had returned when the wait returned.
    /// - Throws: What the wait throws.
    private static func evictionEndedAtReturn(of gate: EvictionGate, in pool: ModelPool) async throws -> Bool {
        try await IntegrationModels.waitForEviction(of: fakeKey, in: pool)
        return gate.hasEnded
    }
}

/// A gate that holds the evict call of ``GatedEvictionLoader`` until the test
/// opens it, and records the start and the end of that call.
private final class EvictionGate: Sendable {
    /// Opens when the evict call starts.
    let started = Latch()

    /// Opens when the test lets the evict call continue.
    private let opened = Latch()

    /// Opens when the evict call returns.
    private let ended = Latch()

    /// Whether the evict call returned.
    var hasEnded: Bool { ended.isOpen }

    /// Runs as the evict call: signals the start, waits until the gate is
    /// open, and signals the end.
    func pass() async {
        started.open()
        await opened.waitUntilOpen()
        ended.open()
    }

    /// Opens the gate, and lets the waiting evict call continue.
    func open() {
        opened.open()
    }
}

/// A loader whose evict call waits at an ``EvictionGate``. A slow eviction of
/// a real model, such as the free of the prompt cache of an MLX model, looks
/// the same to the pool.
private struct GatedEvictionLoader: PooledModelLoader {
    /// The gate of the evict call.
    let gate: EvictionGate

    /// Gives the key as the container: the test needs no model data.
    ///
    /// - Parameter key: The model.
    /// - Returns: `key`.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        key
    }

    /// Waits at the gate.
    ///
    /// - Parameter container: The container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await gate.pass()
    }
}
