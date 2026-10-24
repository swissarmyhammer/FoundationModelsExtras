import FoundationModels
@testable import FoundationModelsExtras
import MLXFoundationModels
import Metrics
import MetricsTestKit
import TelemetryTestSupport
import Testing

/// ``PooledGeneration`` runs one call into a model. The model holds its own
/// FIFO lock for each generation, as MLX does. The helper counts the calls in
/// flight, and a cancel of a call that waits for the lock throws at once.
///
/// Each test uses a ``StubGenerator``: its generations take a FIFO lock with
/// no cancel handler, and check the prompt cache of their session out before
/// the lock, as MLX does. The tests wait on log records and on signals, never
/// on a clock.
@Suite("Pooled generation: one call into a model, an in-flight meter, and a cancel that does not wait for the lock")
struct PooledGenerationTests {
    /// The model of each call.
    private static let ref: ModelRef = "org/chat"

    /// The longest time from the cancel of a waiting call to its error.
    private static let cancelLimit: Duration = .milliseconds(100)

    /// The in-flight count while one generation runs and one waits.
    private static let runningAndWaiting = 2.0

    /// The in-flight count when no call runs.
    private static let noCall = 0.0

    /// One call of a test through ``PooledGeneration``.
    private struct StubCall {
        /// The task of the call.
        let task: Task<Void, any Error>

        /// The events that the channel of the call gave to its reader.
        let events: Recorder<String>

        /// The reader of the channel of the call.
        let reader: Task<Void, Never>

        /// Finish this to end the generation of the call.
        let mayEnd: AsyncStream<Void>.Continuation

        /// Ends the generation of the call.
        func end() {
            mayEnd.finish()
        }
    }

    /// Starts one call of `generator` through ``PooledGeneration`` in a new
    /// task, with the prompt cache scope of `session`.
    ///
    /// - Parameters:
    ///   - name: The name of the generation.
    ///   - session: The id of the session of the call, in `generator`. The
    ///     scope id starts with the session prefix of `generator`.
    ///   - generator: The stub model.
    /// - Returns: The call.
    private static func start(_ name: String, session: String, on generator: StubGenerator) -> StubCall {
        let channel = LanguageModelExecutorGenerationChannel()
        let (events, reader) = StubEvents.read(channel)
        let (mayEndStream, mayEnd) = AsyncStream.makeStream(of: Void.self)
        let scope = MLXLanguageModel.PromptCacheScope.session("\(generator.sessionPrefix)/\(session)")
        let task = Task {
            try await MLXLanguageModel.$promptCacheScope.withValue(scope) {
                try await PooledGeneration.run(ref: ref, channel: channel) { modelChannel in
                    try await generator.generate(name, into: modelChannel, mayEnd: mayEndStream)
                }
            }
        }
        return StubCall(task: task, events: events, reader: reader, mayEnd: mayEnd)
    }

    /// Waits until `log` holds `entry`, or until `call` ends first.
    ///
    /// - Parameters:
    ///   - entry: The entry to wait for.
    ///   - log: The log.
    ///   - call: The call that must write the entry.
    /// - Throws: An `ExpectationFailedError` when the call ended first.
    private static func waitFor(_ entry: String, in log: Recorder<String>, from call: StubCall) async throws {
        await log.waitUntil(holds: entry, orUntilEndOf: call.task)
        try #require(log.values.contains(entry))
    }

    /// The entries of `log` that tell the turns of the lock: each begin, end
    /// and leave, in order.
    ///
    /// - Parameter log: The log of a ``StubGenerator``.
    /// - Returns: The entries with no check-out.
    private static func turns(in log: Recorder<String>) -> [String] {
        log.values.filter { !$0.hasPrefix("checkout ") }
    }

    /// Whether `result` is a `CancellationError`.
    ///
    /// - Parameter result: The result of a call.
    /// - Returns: `true` when the call threw `CancellationError`.
    private static func isCancellation(_ result: Result<Void, any Error>) -> Bool {
        guard case .failure(let error) = result else { return false }
        return error is CancellationError
    }

    @Test(
        "a call that waits behind a running generation and is cancelled throws at once, and the line goes on",
        .timeLimit(.minutes(1)))
    func aCancelledWaiterThrowsAtOnce() async throws {
        let generator = StubGenerator()
        let running = Self.start("A", session: "s1", on: generator)
        try await Self.waitFor("begin A", in: generator.log, from: running)
        let cancelled = Self.start("B", session: "s2", on: generator)
        try await Self.waitFor("B", in: generator.lock.queued, from: cancelled)
        let next = Self.start("C", session: "s3", on: generator)
        try await Self.waitFor("C", in: generator.lock.queued, from: next)

        let cancelStart = ContinuousClock.now
        cancelled.task.cancel()
        let result = await cancelled.task.result
        let cancelTime = ContinuousClock.now - cancelStart

        #expect(Self.isCancellation(result))
        #expect(cancelTime < Self.cancelLimit)
        #expect(Self.turns(in: generator.log) == ["begin A"])

        running.end()
        try await running.task.value
        try await Self.waitFor("begin C", in: generator.log, from: next)
        next.end()
        try await next.task.value

        // A send returns when the reader takes the event, thus the reader can
        // record the event just after the call ended.
        let runningEvents = await running.events.waitUntil { !$0.isEmpty }

        #expect(Self.turns(in: generator.log) == ["begin A", "end A", "leave B", "begin C", "end C"])
        #expect(runningEvents.count == 1)
        #expect(runningEvents.allSatisfy { $0.contains("A") })
        #expect(cancelled.events.values.isEmpty)
        for call in [running, cancelled, next] {
            call.reader.cancel()
        }
    }

    @Test("a cancelled call relays no output into its channel after the cancel", .timeLimit(.minutes(1)))
    func aCancelledCallRelaysNoMoreOutput() async throws {
        let channel = LanguageModelExecutorGenerationChannel()
        let (events, reader) = StubEvents.read(channel)
        defer { reader.cancel() }
        let log = Recorder<String>()
        let (afterCancelStream, afterCancel) = AsyncStream.makeStream(of: Void.self)
        let call = Task {
            try await PooledGeneration.run(ref: Self.ref, channel: channel) { modelChannel in
                await modelChannel.send(StubEvents.text("before"))
                for await _ in afterCancelStream {}
                await modelChannel.send(StubEvents.text("after"))
                log.append("sent after")
            }
        }
        await Waits.untilFirstEnds({ await events.waitUntil { !$0.isEmpty } }, { _ = await call.result })
        try #require(events.values.count == 1)

        call.cancel()
        let result = await call.result
        afterCancel.finish()
        await log.waitUntil { $0.contains("sent after") }
        try await PooledGeneration.run(ref: Self.ref, channel: channel) { modelChannel in
            await modelChannel.send(StubEvents.text("sentinel"))
        }
        let seen = await events.waitUntil { $0.count >= 2 }

        #expect(Self.isCancellation(result))
        #expect(seen.count == 2)
        #expect(seen.first?.contains("before") == true)
        #expect(seen.last?.contains("sentinel") == true)
        #expect(!seen.contains { $0.contains("after") })
    }

    @Test(
        "a new call of the session of a cancelled call starts after the cancelled call left, and sees the cache of the session",
        .timeLimit(.minutes(1)))
    func aNewCallOfTheSameSessionWaitsForTheAbandonedCall() async throws {
        let generator = StubGenerator()
        let dimensions = ModelMetricDimensions.model(Self.ref)
        let (result, waits) = try await TelemetryCapture.run(forbidding: []) { context in
            let warm = Self.start("W", session: "s1", on: generator)
            warm.end()
            try await warm.task.value
            let running = Self.start("X", session: "s2", on: generator)
            try await Self.waitFor("begin X", in: generator.log, from: running)
            let cancelled = Self.start("B", session: "s1", on: generator)
            try await Self.waitFor("B", in: generator.lock.queued, from: cancelled)
            cancelled.task.cancel()
            let result = await cancelled.task.result

            // The new call either waits for the abandoned call, and counts its
            // wait, or goes to the lock at once. The wait ends at the first.
            let next = Self.start("C", session: "s1", on: generator)
            await Waits.untilFirstEnds(
                {
                    await context.wait { context in
                        (try? context.metricsFactory.expectCounter(
                            ExtrasTelemetry.MetricName.generateAbandonedWaits, dimensions)) != nil
                    }
                },
                { await generator.lock.queued.waitUntil { $0.contains("C") } })
            try #require(!generator.lock.queued.values.contains("C"))
            running.end()
            try await running.task.value
            try await Self.waitFor("begin C", in: generator.log, from: next)
            next.end()
            try await next.task.value
            for call in [warm, running, cancelled, next] {
                call.reader.cancel()
            }
            let waits = try context.metricsFactory.expectCounter(
                ExtrasTelemetry.MetricName.generateAbandonedWaits, dimensions
            ).values
            return (result, waits)
        }

        let log = generator.log.values
        #expect(waits == [1])
        #expect(Self.isCancellation(result))
        #expect(log.contains("checkout B W"))
        #expect(log.contains("checkout C W"))
        let leave = try #require(log.firstIndex(of: "leave B"))
        let checkout = try #require(log.firstIndex(of: "checkout C W"))
        #expect(leave < checkout)
    }

    @Test(
        "a call of an other session is not delayed by a cancelled call, beyond its place in the line",
        .timeLimit(.minutes(1)))
    func aCallOfAnOtherSessionDoesNotWaitForTheAbandonedCall() async throws {
        let generator = StubGenerator()
        // A session runs one call at a time, thus the running call has a
        // session of its own.
        let running = Self.start("A", session: "s0", on: generator)
        try await Self.waitFor("begin A", in: generator.log, from: running)
        let cancelled = Self.start("B", session: "s1", on: generator)
        try await Self.waitFor("B", in: generator.lock.queued, from: cancelled)
        cancelled.task.cancel()
        let result = await cancelled.task.result

        let other = Self.start("D", session: "s2", on: generator)
        try await Self.waitFor("D", in: generator.lock.queued, from: other)
        let turnsWhileTheLineWaits = Self.turns(in: generator.log)
        running.end()
        try await running.task.value
        try await Self.waitFor("begin D", in: generator.log, from: other)
        other.end()
        try await other.task.value

        #expect(Self.isCancellation(result))
        #expect(turnsWhileTheLineWaits == ["begin A"])
        #expect(Self.turns(in: generator.log) == ["begin A", "end A", "leave B", "begin D", "end D"])
        for call in [running, cancelled, other] {
            call.reader.cancel()
        }
    }

    @Test(
        "generate.in_flight is 2 while one generation runs and one waits, and 0 after both end",
        .timeLimit(.minutes(1)))
    func theInFlightMeterCountsRunningAndWaitingCalls() async throws {
        let generator = StubGenerator()
        let dimensions = ModelMetricDimensions.model(Self.ref)

        let (whileBothRun, afterBothEnd) = try await TelemetryCapture.run(forbidding: []) { context in
            let running = Self.start("A", session: "s1", on: generator)
            try await Self.waitFor("begin A", in: generator.log, from: running)
            let waiting = Self.start("B", session: "s2", on: generator)
            try await Self.waitFor("B", in: generator.lock.queued, from: waiting)
            let meter = try context.metricsFactory.expectMeter(ExtrasTelemetry.MetricName.generateInFlight, dimensions)
            let whileBothRun = meter.lastValue
            running.end()
            waiting.end()
            try await running.task.value
            try await waiting.task.value
            running.reader.cancel()
            waiting.reader.cancel()
            return (whileBothRun, meter.lastValue)
        }

        #expect(whileBothRun == Self.runningAndWaiting)
        #expect(afterBothEnd == Self.noCall)
    }
}
