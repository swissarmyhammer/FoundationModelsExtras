@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// Exercises ``RunToCompletionRunner``: the result in band, the timeout of one
/// call from ``BackgroundTool``, the timeout that progress starts again and a
/// pending elicitation stops, the terminal events, and one `.completed` on the
/// throw and timeout paths.
///
/// The tests of the timeout window run on a ``ManualRunClock``. Each wait for
/// the timer also ends when the call ends, thus a wrong runner fails the test
/// and does not hang it.
@Suite("RunToCompletionRunner: run the body, return its value")
struct RunToCompletionRunnerTests {
    private typealias Fixtures = MountFixtures

    /// The number of heartbeats of the heartbeat tool.
    private static let heartbeatCount = 8

    /// The timeout, in seconds of the manual clock, of the calls that the
    /// clock tests make.
    private static let clockedTimeout: TimeInterval = 10

    /// The number of full timeout windows that an open question is held for.
    private static let elicitationHoldWindows = 3

    /// The output of ``GatedBeatTool``.
    private static let heartbeatOutput = "heartbeat done"

    /// Posts one progress event when each of its gates opens, in order, then
    /// returns ``heartbeatOutput``.
    private struct GatedBeatTool: Tool {
        let name = "gated_beat_tool"
        let description = "posts one progress event for each gate that opens"

        /// The gate of each beat, in order.
        let gates: [RunLatch]

        func call(arguments: MountArguments) async throws -> String {
            for (beat, gate) in gates.enumerated() {
                await gate.waitUntilOpen()
                await ToolContext.current?.progress(RunToCompletionRunnerTests.beatDetail(beat))
            }
            return RunToCompletionRunnerTests.heartbeatOutput
        }
    }

    /// The detail of the progress event of beat `beat`.
    ///
    /// - Parameter beat: The number of the beat, from 0.
    /// - Returns: The detail.
    private static func beatDetail(_ beat: Int) -> String {
        "beat \(beat)"
    }

    /// One call of a run-to-completion mount on a run plane whose timers wait
    /// on a ``ManualRunClock``.
    private struct ClockedCall {
        /// The clock of the timers of the call.
        let clock: ManualRunClock

        /// The run plane of the call.
        let runPlane: RunPlane

        /// The sink of the call.
        let sink: Fixtures.RecordingSink

        /// The task of the call.
        let calling: Task<String, any Error>

        /// Starts one call of `tool` with the timeout `timeout`.
        ///
        /// - Parameters:
        ///   - tool: The tool.
        ///   - timeout: The timeout of the mount, or `nil` for none.
        /// - Returns: The call.
        static func start(_ tool: any Tool<MountArguments, String>, timeout: TimeInterval?) -> ClockedCall {
            let clock = ManualRunClock()
            let runPlane = RunPlane(clock: clock)
            let sink = Fixtures.RecordingSink()
            let mounted = RunToCompletionRunner(
                wrapping: tool, site: Fixtures.site(runPlane: runPlane, sink: sink), timeout: timeout)
            let calling = Task { try await mounted.call(arguments: MountArguments(value: "x")) }
            return ClockedCall(clock: clock, runPlane: runPlane, sink: sink, calling: calling)
        }

        /// Waits until the timer of the call waits on the clock, or until the
        /// call ends first.
        func waitForTheTimer() async {
            let clock = clock
            let calling = calling
            await Waits.untilFirstEnds({ await clock.waitForSleepers(atLeast: 1) }, { _ = await calling.result })
        }

        /// Moves the clock by `seconds`.
        ///
        /// - Parameter seconds: How far the clock moves.
        func advance(seconds: TimeInterval) {
            clock.advance(by: .seconds(seconds))
        }

        /// Waits until the call ends, or until the timer waits again first.
        /// The test then reads ``ManualRunClock/sleeperCount``: a timer that
        /// waits again tells that the timeout did not end the call.
        func waitForTheEnd() async {
            let clock = clock
            let calling = calling
            await Waits.untilFirstEnds({ _ = await calling.result }, { await clock.waitForSleepers(atLeast: 1) })
        }
    }

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
        let call = ClockedCall.start(
            Fixtures.PerCallTimeoutTool(timeoutSeconds: Fixtures.shortInterval), timeout: Fixtures.generousInterval)

        // The timer ends at the timeout of the call, not at the mount timeout.
        await #expect(throws: ToolMountError.self) {
            _ = try await call.clock.elapse(Fixtures.shortInterval, endingWait: call.calling)
        }

        let events = await call.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("a nil per-call timeout uses the mount timeout")
    func nilPerCallTimeoutFallsBackToMount() async throws {
        let call = ClockedCall.start(Fixtures.NilTimeoutTool(), timeout: Fixtures.shortInterval)

        await #expect(throws: ToolMountError.self) {
            _ = try await call.clock.elapse(Fixtures.shortInterval, endingWait: call.calling)
        }

        let events = await call.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - The timeout

    @Test("progress starts the timeout again: a tool that beats faster than the timeout runs past it")
    func progressResetsTimeout() async throws {
        let gates = (0..<Self.heartbeatCount).map { _ in RunLatch() }
        let call = ClockedCall.start(GatedBeatTool(gates: gates), timeout: Self.clockedTimeout)

        // Each beat comes in the middle of a window, and each window ends
        // after the beat. The whole run is longer than one timeout.
        for (beat, gate) in gates.enumerated() {
            await call.waitForTheTimer()
            call.advance(seconds: Self.clockedTimeout / 2)
            gate.open()
            let detail = Self.beatDetail(beat)
            let calling = call.calling
            await Waits.untilFirstEnds(
                { await call.sink.waitForAnEvent { $0.detail == detail } }, { _ = await calling.result })
            call.advance(seconds: Self.clockedTimeout / 2)
        }

        let rendered = try await call.calling.value
        #expect(rendered == Self.heartbeatOutput)
        let events = await call.sink.events
        #expect(events.last?.kind == .completed)
        #expect(events.last?.outcome == .succeeded)
    }

    @Test("the timeout cancels the work and throws the one named error, with outcome timedOut")
    func timeoutExpiryThrowsNamedError() async throws {
        let call = ClockedCall.start(Fixtures.SleepingTool(), timeout: Fixtures.shortInterval)

        await #expect(throws: ToolMountError.self) {
            _ = try await call.clock.elapse(Fixtures.shortInterval, endingWait: call.calling)
        }

        let events = await call.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("the timeout also sets the cooperative flag that the tool reads")
    func timeoutSetsCancellationFlag() async throws {
        let witness = Fixtures.CancellationWitness()
        let call = ClockedCall.start(Fixtures.CancellationFlagTool(witness: witness), timeout: Fixtures.shortInterval)

        await #expect(throws: ToolMountError.self) {
            _ = try await call.clock.elapse(Fixtures.shortInterval, endingWait: call.calling)
        }

        // The runner sets the flag before the timeout returns, so the flag
        // that the tool reads is set now.
        #expect(await witness.context.value.isCancelled)

        let events = await call.sink.events
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

    @Test("a pending elicitation stops the timeout while it has no answer")
    func pendingElicitationSuspendsTimeout() async throws {
        let call = ClockedCall.start(Fixtures.ElicitOnceTool(), timeout: Self.clockedTimeout)
        let calling = call.calling
        let elicitationId = try await Fixtures.firstQuestionId(postedTo: call.sink) { _ = await calling.result }

        // Hold the answer across more than one full timeout window. After
        // each window the timer waits again, so the call still runs.
        for _ in 0..<Self.elicitationHoldWindows {
            await call.waitForTheTimer()
            call.advance(seconds: Self.clockedTimeout)
        }
        await call.waitForTheTimer()
        #expect(call.clock.sleeperCount == 1)

        await call.runPlane.respond(elicitationId: elicitationId, .accept(content: ["ok": .boolean(true)]))
        await OpenQuestions.endIfOpen(elicitationId, on: call.runPlane)

        let rendered = try await call.calling.value
        #expect(rendered == "answered: accept")
        let events = await call.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .succeeded)
    }

    @Test("an answered elicitation starts a new timeout window: a run that then stalls still times out")
    func elicitationResolutionRestoresTimeout() async throws {
        let call = ClockedCall.start(Fixtures.ElicitThenStallTool(), timeout: Self.clockedTimeout)
        let calling = call.calling
        let elicitationId = try await Fixtures.firstQuestionId(postedTo: call.sink) { _ = await calling.result }
        await call.waitForTheTimer()

        await call.runPlane.respond(elicitationId: elicitationId, .decline)
        await OpenQuestions.endIfOpen(elicitationId, on: call.runPlane)

        // The window of the open question ends, and the answer starts a new
        // full window. At the end of that window, the stalled run times out.
        call.advance(seconds: Self.clockedTimeout)
        await call.waitForTheTimer()
        call.advance(seconds: Self.clockedTimeout)
        await call.waitForTheEnd()
        try #require(call.clock.sleeperCount == 0, "the timeout did not end the call")

        await #expect(throws: ToolMountError.self) {
            _ = try await call.calling.value
        }
        let events = await call.sink.events
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

    @Test("with no timeout, a call waits until the tool ends, never goes to the background, and starts no timer")
    func clocklessCallBlocksUntilTheToolFinishes() async throws {
        let open = RunLatch()
        open.open()
        let started = RunLatch()
        let finish = RunLatch()
        let call = ClockedCall.start(
            Fixtures.HeartbeatTool(beats: 0, gate: open, beaten: started, finish: finish), timeout: nil)
        let calling = call.calling
        await Waits.untilFirstEnds({ await started.waitUntilOpen() }, { _ = await calling.result })

        // The tool runs and waits on its gate. A call with no timeout starts
        // no timer, and it does not go to the background.
        #expect(call.clock.sleeperCount == 0)
        #expect(await call.runPlane.backgroundRuns().isEmpty)
        finish.open()

        let rendered = try await call.calling.value
        #expect(rendered == Self.heartbeatOutput)
        #expect(await call.runPlane.backgroundRuns().isEmpty)
        // A slow call is not a failed call: the run settles with no event.
        #expect(await call.sink.events.isEmpty)
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
