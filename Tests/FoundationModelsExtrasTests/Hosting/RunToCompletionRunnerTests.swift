@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// Exercises ``RunToCompletionRunner``: the result in band, the timeout of one
/// call from ``BackgroundTool``, the timeout that progress starts again and a
/// pending elicitation stops, the terminal events, and one `.completed` on the
/// throw and timeout paths.
@Suite("RunToCompletionRunner: run the body, return its value")
struct RunToCompletionRunnerTests {
    private typealias Fixtures = MountFixtures

    /// The number of heartbeats of the heartbeat tool.
    private static let heartbeatCount = 8

    /// The pause between two heartbeats, well inside ``heartbeatTimeout``.
    private static let heartbeatInterval: TimeInterval = 0.1

    /// The timeout that the heartbeats start again. The whole run is longer.
    private static let heartbeatTimeout: TimeInterval = 0.5

    /// The number of ``MountFixtures/shortInterval`` windows that a call with
    /// no timeout is held for.
    private static let clocklessHoldWindows: Double = 3

    /// The number of timeout windows that an answer is held for.
    private static let elicitationHoldWindows: Double = 3

    // MARK: - In band

    @Test("a fast tool returns its output in band and posts no events")
    func fastToolIsSilent() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.FastTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "fast: x")
        #expect(await harness.sink.events.isEmpty)
        #expect(await harness.runPlane.backgroundRuns().isEmpty)
    }

    // MARK: - The timeout of one call

    @Test("a per-call timeout wins over the mount timeout")
    func perCallTimeoutOverridesMount() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.PerCallTimeoutTool(timeoutSeconds: Fixtures.shortInterval),
            timeout: Fixtures.generousInterval
        )

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("a nil per-call timeout uses the mount timeout")
    func nilPerCallTimeoutFallsBackToMount() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.NilTimeoutTool(), timeout: Fixtures.shortInterval)

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - The timeout

    @Test("progress starts the timeout again: a tool that beats faster than the timeout runs past it")
    func progressResetsTimeout() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.HeartbeatTool(beats: Self.heartbeatCount, interval: Self.heartbeatInterval),
            timeout: Self.heartbeatTimeout
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "heartbeat done")
        let events = await harness.sink.events
        #expect(events.last?.kind == .completed)
        #expect(events.last?.outcome == .succeeded)
    }

    @Test("the timeout cancels the work and throws the one named error, with outcome timedOut")
    func timeoutExpiryThrowsNamedError() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.SleepingTool(), timeout: Fixtures.shortInterval)

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("the timeout also sets the cooperative flag that the tool reads")
    func timeoutSetsCancellationFlag() async throws {
        let witness = Fixtures.CancellationWitness()
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.CancellationFlagPollingTool(witness: witness),
            timeout: Fixtures.shortInterval
        )

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        // The race ended as timedOut. The tool polls until the flag that the
        // timeout set reaches it.
        let observed = try await Fixtures.poll { await witness.observed ? true : nil }
        #expect(observed == true)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - Terminal events

    @Test("a run with only progress still gets one terminal event")
    func progressOnlyRunGetsSynthesizedTerminal() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ProgressOnceTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "progressed: x")
        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.last?.outcome == .succeeded)
        #expect(events.last?.detail == "progressed: x")
    }

    @Test("a tool that posts its own terminal event gets no second one")
    func ownTerminalToolGetsNoDuplicate() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.OwnTerminalTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "own-terminal: x")
        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.detail == "my own terminal")
    }

    @Test("a tool that throws throws again in band and gets one terminal event with outcome failed")
    func throwingToolYieldsOneFailedTerminal() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ThrowingTool())

        await #expect(throws: Fixtures.FixtureError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .failed)
    }

    // MARK: - An elicitation stops the timeout

    @Test("a pending elicitation stops the timeout while it has no answer", .timeLimit(.minutes(1)))
    func pendingElicitationSuspendsTimeout() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ElicitOnceTool(), timeout: Fixtures.shortInterval)

        let calling = AnswerDrivenRun(waitingFor: "the tool call blocked on its elicitation") {
            try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }
        let elicitationId = try await Fixtures.firstPendingElicitationId(in: harness.runPlane)

        // Hold the answer across more than one timeout window.
        try await Task.sleep(for: .seconds(Fixtures.shortInterval * Self.elicitationHoldWindows))
        await harness.runPlane.respond(elicitationId: elicitationId, .accept(content: ["ok": .boolean(true)]))

        let rendered = try await calling.answerOnceDelivered()
        #expect(rendered == "answered: accept")

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .succeeded)
    }

    @Test(
        "an answered elicitation starts a new timeout window: a run that then stalls still times out",
        .timeLimit(.minutes(1)))
    func elicitationResolutionRestoresTimeout() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ElicitThenStallTool(), timeout: Fixtures.shortInterval)

        let calling = AnswerDrivenRun(waitingFor: "the tool call blocked on its elicitation") {
            try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }
        let elicitationId = try await Fixtures.firstPendingElicitationId(in: harness.runPlane)
        await harness.runPlane.respond(elicitationId: elicitationId, .decline)

        await #expect(throws: ToolMountError.self) {
            _ = try await calling.answerOnceDelivered()
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - Attachments

    @Test("two attach calls in a run land on its settlement in call order")
    func attachmentsLandOnTheSettlementInCallOrder() async throws {
        let sink = Fixtures.RecordingSink()
        let arguments = MountArguments(value: "x")
        let run = Fixtures.toolRun(wrapping: Fixtures.AttachingTool(), arguments: arguments, sink: sink)

        await run.open()
        let settlement = await run.execute(arguments: arguments)

        #expect(settlement.attachments == Fixtures.attachmentsInCallOrder)
        #expect(try settlement.result.get() == "attached: x")
    }

    @Test("attachments never reach the output or an event of a run-to-completion call")
    func attachmentsStayOutOfTheModelFacingOutput() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.AttachingTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "attached: x")
        #expect(!Fixtures.isAttachmentMentioned(in: rendered))
        // A silent success posts no event, so no detail can hold a record.
        #expect(await harness.sink.events.isEmpty)
    }

    // MARK: - No timeout

    @Test("the synchronous mount runs to completion and has no timeout")
    func synchronousMountCarriesNoTimeout() {
        #expect(ToolMount.synchronous.mode == .runToCompletion)
        #expect(ToolMount.synchronous.timeout == nil)
    }

    @Test("a mount that states no timeout has no timeout")
    func unstatedTimeoutIsNil() {
        #expect(ToolMount(mode: .runToCompletion).timeout == nil)
        #expect(ToolMount(mode: .background).timeout == nil)
    }

    @Test("with no timeout, a call waits until the tool ends, never goes to the background, and reports no timeout")
    func clocklessCallBlocksUntilTheToolFinishes() async throws {
        let gate = RunLatch()
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.GatedTool(gate: gate), timeout: nil)

        let calling = Task {
            try await harness.mounted.call(arguments: MountArguments(value: "discovery"))
        }
        // Hold the tool past the window in which a timeout would stop it.
        try await Task.sleep(for: .seconds(Fixtures.shortInterval * Self.clocklessHoldWindows))
        #expect(await harness.runPlane.backgroundRuns().isEmpty)
        gate.open()

        let rendered = try await calling.value
        #expect(rendered == "gated: discovery")
        #expect(await harness.runPlane.backgroundRuns().isEmpty)
        // A slow call is not a failed call: the run settles with no event.
        #expect(await harness.sink.events.isEmpty)
    }

    @Test("with no timeout, only the error of the tool reaches the model")
    func clocklessCallReportsOnlyRealErrors() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ThrowingTool(), timeout: nil)

        await #expect(throws: Fixtures.FixtureError()) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .failed)
    }
}
