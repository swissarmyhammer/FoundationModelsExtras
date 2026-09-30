import FoundationModelsExtras
import Testing

/// The model of the eviction-wait test. No loader downloads it: the fake
/// loader of the test gives a container for each key.
private let fakeKey = ModelPoolKey(ref: "fake/gated-eviction", role: .llm)

/// The bytes that the pool counts for the fake model.
private let fakeFootprintBytes: Int64 = 1

/// The milliseconds of ``gateDelay``.
private let gateDelayMilliseconds = 100

/// The time from the start of the wait to the end of the fake eviction. A wait
/// that does not wait for the eviction returns in this time, and the test then
/// sees an eviction that did not end. A correct wait passes at each delay.
private let gateDelay = Duration.milliseconds(gateDelayMilliseconds)

/// The longest time that the eviction-wait test may take. A wait that never
/// returns fails the test.
private let evictionWaitTimeLimitMinutes = 1

/// The test of the helper that each real-model test calls after its last
/// release. A fake loader makes the eviction slow, thus the test needs no real
/// model and no MLX.
@Suite("The eviction wait of the real-model tests", .timeLimit(.minutes(evictionWaitTimeLimitMinutes)))
struct EvictionWaitTests {
    @Test("waitForEviction returns only after the evict call of the loader returned")
    func waitForEvictionReturnsAfterTheEvictCall() async throws {
        let gate = EvictionGate()
        let pool = ModelPool()
        try await Self.acquireAndRelease(in: pool, loader: GatedEvictionLoader(gate: gate))
        // The eviction job runs, and its evict call waits at the gate.
        try await Waiting.until { await gate.hasStarted }

        async let evictionEndedAtReturn = Self.evictionEndedAtReturn(of: gate, in: pool)
        try await Task.sleep(for: gateDelay)
        await gate.open()

        #expect(try await evictionEndedAtReturn)
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
        return await gate.hasEnded
    }
}

/// A gate that holds the evict call of ``GatedEvictionLoader`` until the test
/// opens it, and records the start and the end of that call.
private actor EvictionGate {
    /// Whether the evict call started.
    private(set) var hasStarted = false
    /// Whether the evict call returned.
    private(set) var hasEnded = false
    /// Whether the test opened the gate.
    private var isOpen = false
    /// The evict call that waits at the gate, or `nil`.
    private var waiting: CheckedContinuation<Void, Never>?

    /// Runs as the evict call: waits until the gate is open.
    func pass() async {
        hasStarted = true
        if !isOpen {
            await withCheckedContinuation { waiting = $0 }
        }
        hasEnded = true
    }

    /// Opens the gate, and lets the waiting evict call continue.
    func open() {
        isOpen = true
        waiting?.resume()
        waiting = nil
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
