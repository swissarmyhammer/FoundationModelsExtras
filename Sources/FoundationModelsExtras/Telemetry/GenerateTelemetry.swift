import FoundationModels
import Metrics
import Synchronization
import Tracing

/// The recorder of the telemetry of one generation call of a pooled LLM: the
/// generate span, the time-to-first-token timer, the duration timer, the
/// output token counter and the tokens-per-second recorder.
///
/// ``traceGenerate(of:guided:_:)`` opens the span through ``TracedCall``
/// before the load of the model and before the wait in the queue of the
/// model. Thus a call that hangs shows as an "enter" record with no span that
/// ends, and the load span and each tool span that opens in the call are
/// children of the generate span. The queue job restores the trace context of
/// its submitter, thus a span inside the model run keeps that parent.
///
/// The ``GenerateCall`` of the call relays each model round. The model sends
/// its events into a new channel, and the relay sends each event on to the
/// channel of the session. The relay sees the first event and the end of the
/// round, and the token counts of the `updateUsage` events.
///
/// Each metric is made at call time, so that it uses the metrics factory of
/// the current task.
///
/// The recorder records the model ref, two flags, durations and token counts
/// only. It never records a prompt, the instructions, the transcript or the
/// text of an answer.
enum GenerateTelemetry {
    /// Runs one generation call of `ref` in one generate span, and records
    /// its timers and token metrics.
    ///
    /// The span has the model ref and the guided flag of the call. `body`
    /// sets the cold flag with ``GenerateCall/markCold(_:)``. The timers
    /// record as the last step of the span, on the success path and on the
    /// error path, with the ``ModelOperationOutcome`` of the call. Thus the
    /// duration and the span measure the same interval, and a failed call
    /// also records its duration.
    ///
    /// - Parameters:
    ///   - ref: The model of the call.
    ///   - guided: Whether the call gives a generation schema to the model.
    ///   - body: The call. It gets the recorder of the call, and it runs on
    ///     the actor of the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span gets the error status and the
    ///   type of the error, never its description.
    nonisolated(nonsending) static func traceGenerate<Output>(
        of ref: ModelRef,
        guided: Bool,
        _ body: nonisolated(nonsending) (GenerateCall) async throws -> Output
    ) async throws -> Output {
        let start = ContinuousClock.now
        return try await TracedCall.run(
            ExtrasTelemetry.SpanName.generate,
            logger: ExtrasTelemetry.makeLogger(),
            attributes: { attributes in
                attributes[ExtrasTelemetry.AttributeKey.modelRef] = ref.stringValue
                attributes[ExtrasTelemetry.AttributeKey.generateGuided] = guided
            },
            metadata: [ExtrasTelemetry.LogMetadataKey.modelRef: .string(ref.stringValue)]
        ) { span in
            let call = GenerateCall(ref: ref, span: span, start: start)
            do {
                let output = try await body(call)
                call.record(outcome: .succeeded)
                return output
            } catch {
                call.record(outcome: .failed)
                throw error
            }
        }
    }

    /// The deepest level of the value tree of an event that
    /// ``outputTokenCount(in:)`` reads. The `Usage` value of an
    /// `updateUsage` event is at the fifth level.
    private static let deepestEventLevel = 8

    /// Gives the output token count of `event` when it is an `updateUsage`
    /// event.
    ///
    /// The event type shows no public value, thus the function reads its
    /// value tree by reflection and finds the public `Usage` value in it.
    ///
    /// - Parameter event: An event of a model.
    /// - Returns: The total output token count of the usage, or `nil` when
    ///   the event holds no usage.
    static func outputTokenCount(in event: LanguageModelExecutorGenerationChannel.Event) -> Int? {
        usage(in: Mirror(reflecting: event), level: 1)?.output.totalTokenCount
    }

    /// Finds the first `Usage` value in the children of `mirror`, from the
    /// first child to the last, each child before its own children.
    ///
    /// - Parameters:
    ///   - mirror: The mirror of a value of an event.
    ///   - level: The level of the children of `mirror` in the value tree.
    /// - Returns: The usage, or `nil` when the tree holds none up to
    ///   ``deepestEventLevel``.
    private static func usage(in mirror: Mirror, level: Int) -> LanguageModelExecutorGenerationChannel.Usage? {
        guard level <= deepestEventLevel else { return nil }
        for child in mirror.children {
            if let usage = child.value as? LanguageModelExecutorGenerationChannel.Usage {
                return usage
            }
            if let usage = usage(in: Mirror(reflecting: child.value), level: level + 1) {
                return usage
            }
        }
        return nil
    }
}

/// The recorder of one generation call: the instant of its first event, its
/// output token count, and the time of its model rounds.
///
/// A call has one model round for each executor call of the model. A
/// ``PooledSession`` respond call with a tool call has a round before the
/// tool call and a round after it.
final class GenerateCall: Sendable {
    /// What the rounds of the call saw.
    private struct Rounds {
        /// The instant of the first event of the call, or `nil` before it.
        var firstEvent: ContinuousClock.Instant?

        /// The output tokens of the rounds that ended, or `nil` when no
        /// round gave a token count.
        var outputTokens: Int?

        /// The output tokens of the last `updateUsage` event of the round
        /// that runs, or `nil` when it gave none. A later usage of one round
        /// replaces the earlier one.
        var roundOutputTokens: Int?

        /// The time of the rounds that ended.
        var modelTime: Duration = .zero
    }

    /// One second, the unit of the tokens-per-second recorder.
    private static let oneSecond: Duration = .seconds(1)

    /// The model of the call.
    private let ref: ModelRef

    /// The generate span of the call.
    private let span: any Span

    /// The instant that the call started.
    private let start: ContinuousClock.Instant

    /// What the rounds of the call saw.
    private let rounds = Mutex(Rounds())

    /// Makes the recorder of one call.
    ///
    /// - Parameters:
    ///   - ref: The model of the call.
    ///   - span: The generate span of the call.
    ///   - start: The instant that the call started.
    fileprivate init(ref: ModelRef, span: any Span, start: ContinuousClock.Instant) {
        self.ref = ref
        self.span = span
        self.start = start
    }

    /// Gives the generate span the cold flag of the call.
    ///
    /// - Parameter cold: Whether the call included a load of the model.
    func markCold(_ cold: Bool) {
        span.attributes[ExtrasTelemetry.AttributeKey.generateCold] = cold
    }

    /// Runs one model round, and relays each event of the model to
    /// `channel`.
    ///
    /// `run` gets a new channel. Each event that the model sends into it goes
    /// on to `channel`, in order. The call returns when `run` returned and
    /// `channel` took each event.
    ///
    /// - Parameters:
    ///   - channel: The channel of the session.
    ///   - run: Runs the model with the channel that it gets.
    /// - Throws: The error of `run`.
    func relay(
        into channel: LanguageModelExecutorGenerationChannel,
        _ run: (LanguageModelExecutorGenerationChannel) async throws -> Void
    ) async throws {
        let roundStart = ContinuousClock.now
        defer { endRound(startedAt: roundStart) }
        try await GenerateChannelRelay.relay(into: channel, of: ref, observing: observe, run)
    }

    /// Records the first event, and keeps the output token count of a usage
    /// event.
    ///
    /// - Parameter event: An event of the model.
    private func observe(_ event: LanguageModelExecutorGenerationChannel.Event) {
        let now = ContinuousClock.now
        let outputTokens = GenerateTelemetry.outputTokenCount(in: event)
        rounds.withLock { rounds in
            rounds.firstEvent = rounds.firstEvent ?? now
            rounds.roundOutputTokens = outputTokens ?? rounds.roundOutputTokens
        }
    }

    /// Adds the time and the output tokens of the round that ends.
    ///
    /// - Parameter roundStart: The instant that the round started.
    private func endRound(startedAt roundStart: ContinuousClock.Instant) {
        let now = ContinuousClock.now
        rounds.withLock { rounds in
            rounds.modelTime += now - roundStart
            if let roundOutputTokens = rounds.roundOutputTokens {
                rounds.outputTokens = (rounds.outputTokens ?? 0) + roundOutputTokens
            }
            rounds.roundOutputTokens = nil
        }
    }

    /// Records the timers of the call with `outcome`, and its token metrics
    /// when a round gave a token count.
    ///
    /// - Parameter outcome: How the call ended.
    fileprivate func record(outcome: ModelOperationOutcome) {
        let end = ContinuousClock.now
        let seen = rounds.withLock { $0 }
        let timerDimensions = dimensions + [(ExtrasTelemetry.DimensionKey.modelOutcome, outcome.rawValue)]
        Metrics.Timer(label: ExtrasTelemetry.MetricName.generateDuration, dimensions: timerDimensions)
            .record(duration: end - start)
        if let firstEvent = seen.firstEvent {
            Metrics.Timer(label: ExtrasTelemetry.MetricName.generateTimeToFirstToken, dimensions: timerDimensions)
                .record(duration: firstEvent - start)
        }
        if let outputTokens = seen.outputTokens {
            recordTokens(outputTokens, in: seen.modelTime)
        }
    }

    /// Adds `outputTokens` to the output token counter, and records the
    /// tokens per second of the call when its model time is not zero.
    ///
    /// - Parameters:
    ///   - outputTokens: The output tokens of the call.
    ///   - modelTime: The time of the model rounds of the call.
    private func recordTokens(_ outputTokens: Int, in modelTime: Duration) {
        Metrics.Counter(label: ExtrasTelemetry.MetricName.generateOutputTokens, dimensions: dimensions)
            .increment(by: outputTokens)
        guard modelTime > .zero else { return }
        Metrics.Recorder(label: ExtrasTelemetry.MetricName.generateTokensPerSecond, dimensions: dimensions)
            .record(Double(outputTokens) / (modelTime / Self.oneSecond))
    }

    /// The dimensions of each generate metric: the model ref.
    private var dimensions: [(String, String)] {
        [(ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue)]
    }
}

/// The relay of the events of one model round from the channel of the model
/// to the channel of the session.
///
/// A generation channel is a rendezvous channel: a send returns only when a
/// reader takes the event, and the channel has no public end. Thus the relay
/// has two parts. A pump reads the channel of the model, and puts each event
/// in a buffered stream. A forwarder reads the stream, and sends each event
/// to the channel of the session. When the model run returns, each event that
/// it sent is in the stream, because each send returned. The relay then
/// cancels the pump, which ends the stream, and the forwarder sends the last
/// events and ends.
private enum GenerateChannelRelay {
    /// The type of the events of a model.
    typealias Event = LanguageModelExecutorGenerationChannel.Event

    /// Runs `run` with a new channel, and relays each event of that channel
    /// to `channel`.
    ///
    /// - Parameters:
    ///   - channel: The channel of the session.
    ///   - ref: The model of the round, for the error record of a failed
    ///     read.
    ///   - observe: Sees each event before it goes on to `channel`.
    ///   - run: Runs the model with the channel that it gets.
    /// - Throws: The error of `run`.
    static func relay(
        into channel: LanguageModelExecutorGenerationChannel,
        of ref: ModelRef,
        observing observe: @escaping @Sendable (Event) -> Void,
        _ run: (LanguageModelExecutorGenerationChannel) async throws -> Void
    ) async throws {
        let modelChannel = LanguageModelExecutorGenerationChannel()
        let (events, buffer) = AsyncStream.makeStream(of: Event.self)
        async let forwarded: Void = forward(events, into: channel)
        let failure = await withTaskGroup(of: Void.self) { group -> (any Error)? in
            group.addTask { await pump(modelChannel, into: buffer, of: ref, observing: observe) }
            defer { group.cancelAll() }
            do {
                try await run(modelChannel)
                return nil
            } catch {
                return error
            }
        }
        await forwarded
        if let failure {
            throw failure
        }
    }

    /// Reads each event of `modelChannel` until the task is cancelled, gives
    /// it to `observe`, and puts it in `buffer`. Then ends `buffer`.
    ///
    /// - Parameters:
    ///   - modelChannel: The channel of the model.
    ///   - buffer: The stream of the forwarder.
    ///   - ref: The model of the round.
    ///   - observe: Sees each event.
    private static func pump(
        _ modelChannel: LanguageModelExecutorGenerationChannel,
        into buffer: AsyncStream<Event>.Continuation,
        of ref: ModelRef,
        observing observe: @Sendable (Event) -> Void
    ) async {
        defer { buffer.finish() }
        do {
            for try await event in modelChannel {
                observe(event)
                buffer.yield(event)
            }
        } catch {
            // Only a failed channel throws, and nothing fails the new channel
            // of a round. A failure is a defect, thus the debug build stops,
            // and the release build writes an error record.
            assertionFailure("the channel of a model round failed")
            PoolTelemetry.logGenerateRelayFailure(error, of: ref)
        }
    }

    /// Sends each event of `events` to `channel`, in order, until `events`
    /// ends.
    ///
    /// - Parameters:
    ///   - events: The stream of the pump.
    ///   - channel: The channel of the session.
    private static func forward(_ events: AsyncStream<Event>, into channel: LanguageModelExecutorGenerationChannel) async {
        for await event in events {
            await channel.send(event)
        }
    }
}

