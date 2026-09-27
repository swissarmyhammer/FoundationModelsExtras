@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises ``BackgroundToolRunner``: the envelope of each call, the run on
/// the run plane, the events, the timeout of a background run, the canceler,
/// the run-plane list, and one `.completed` for a natural settle, a cancel and
/// a timeout.
@Suite("BackgroundToolRunner: start the body, return the handle at once")
struct BackgroundToolRunnerTests {
    private typealias Fixtures = MountFixtures

    /// The number of heartbeats of a run that beats after the handle returns.
    private static let beatingRunBeats = 20

    /// The number of heartbeats of the tool of the run-plane list test.
    private static let snapshotRunBeats = 40

    /// The pause between two heartbeats.
    private static let heartbeatInterval: TimeInterval = 0.05

    /// A sink that stages each event for a later prompt, and takes back the
    /// events of a run on request.
    private actor StagingSink: OperationEventSink, StagedEventWithdrawing {
        /// The staged events, in post order.
        private(set) var staged: [OperationEvent] = []

        func post(event: OperationEvent) {
            staged.append(event)
        }

        func withdrawStagedEvents(correlationID: String) {
            staged.removeAll { $0.correlationID == correlationID }
        }
    }

    // MARK: - The handle of each call

    @Test("a background tool whose body ends at once still returns a PendingRunEnvelope: the run is tracked before the body runs")
    func instantBodyStillReturnsEnvelope() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.TrackedAtStartTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "instant"))

        #expect(PendingRunEnvelope.isRendered(text: rendered))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == Fixtures.TrackedAtStartTool.trackedOutput)
        #expect(terminal.outcome == .succeeded)
        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
    }

    @Test("a background call returns at once: pending envelope, run-plane entry, one progress, one terminal event")
    func backgroundCallIsHandedBackAtOnce() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.GatedTool(gate: gate))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "slow"))

        // The pending envelope: the pending flag and a ULID completion token.
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(ULID(ulidString: envelope.completionToken) != nil)

        // The run plane holds the run under that token, of kind swiftTask.
        let status = await harness.runPlane.backgroundRuns()
        #expect(status.count == 1)
        #expect(status.first?.completionToken == envelope.completionToken)
        #expect(status.first?.kind == .swiftTask)
        #expect(status.first?.tool == "gated_tool")

        // One progress event at the return, on the correlation of the run.
        let eventsAtHandBack = await harness.sink.events
        #expect(eventsAtHandBack.count == 1)
        #expect(eventsAtHandBack.first?.kind == .progress)
        #expect(eventsAtHandBack.first?.correlationID == envelope.completionToken)
        #expect(eventsAtHandBack.first?.tool == "gated_tool")

        // Settle the run. The terminal event holds the output as its detail,
        // the token as its correlationID and the outcome succeeded, and it
        // went to the sink although wait() collected it here.
        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.kind == .completed)
        #expect(terminal.detail == "gated: slow")
        #expect(terminal.correlationID == envelope.completionToken)
        #expect(terminal.outcome == .succeeded)

        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.last?.detail == "gated: slow")
        #expect(events.last?.outcome == .succeeded)
        #expect(events.last?.correlationID == envelope.completionToken)
    }

    @Test("a tool that gives its own collect sentence gets that sentence as the next field of the envelope")
    func toolSuppliedCollectInstructionIsRendered() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.CollectSentenceTool(gate: gate), timeout: nil)

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "own sentence"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(envelope.next == Fixtures.CollectSentenceTool.collectInstruction(forCompletionToken: envelope.completionToken))
        #expect(rendered == PendingRunEnvelope(completionToken: envelope.completionToken, next: envelope.next).rendered)

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == "collected: own sentence")
    }

    // MARK: - The wait before the handle

    @Test("a run that settles in the grace of its tool answers with the result in the same envelope, and the run plane still reports that result")
    func runSettlingInsideTheGraceAnswersInline() async throws {
        let gate = RunLatch()
        // Open already, so the body returns when it starts, before the grace.
        gate.open()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "now"))

        #expect(PendingRunEnvelope.isRendered(text: rendered))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        #expect(envelope.outcome == OperationOutcome.succeeded.rawValue)
        #expect(envelope.detail == Fixtures.InlineGraceTool.output(for: "now"))
        #expect(envelope.next == Fixtures.InlineGraceTool.resultInstruction(forCompletionToken: envelope.completionToken))

        // The run settled by itself, so the run plane holds the same result
        // for a model that calls wait on the token.
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == Fixtures.InlineGraceTool.output(for: "now"))
        #expect(terminal.outcome == .succeeded)

        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
    }

    @Test("a tool that declares a grace and no sentence of its own gets the default settled sentence")
    func settledEnvelopeTakesTheDefaultSentence() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.DefaultSentenceGraceTool(grace: Fixtures.generousInterval))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "now"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        #expect(envelope.detail == Fixtures.DefaultSentenceGraceTool.output(for: "now"))
        #expect(envelope.next == PendingRunEnvelope.defaultResultInstruction(forCompletionToken: envelope.completionToken))
    }

    @Test("a run that continues after the grace answers with the pending envelope, and settles behind it")
    func runStillGoingWhenTheGraceElapsesAnswersPending() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.shortInterval))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "later"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(envelope.detail == nil)
        #expect(envelope.outcome == nil)
        #expect(envelope.next == PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: envelope.completionToken))

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == Fixtures.InlineGraceTool.output(for: "later"))
    }

    @Test("an inline result leaves nothing staged for a later prompt, and a pending run still stages its progress")
    func inlineResultWithdrawsWhatTheRunStaged() async throws {
        let runPlane = RunPlane()
        let sink = StagingSink()
        let site = Fixtures.site(runPlane: runPlane, sink: sink)
        let gate = RunLatch()
        gate.open()
        let inline = BackgroundToolRunner(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval), site: site, timeout: nil
        )

        let rendered = try await inline.call(arguments: MountArguments(value: "inline"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        #expect(await sink.staged.isEmpty)

        // The same sink still stages a run whose result the model does not
        // have, so only a settled run takes its events back.
        let held = RunLatch()
        let pendingRun = BackgroundToolRunner(wrapping: Fixtures.GatedTool(gate: held), site: site, timeout: nil)

        let pendingRendered = try await pendingRun.call(arguments: MountArguments(value: "held"))

        let pendingEnvelope = try Fixtures.decodeEnvelope(pendingRendered)
        #expect(pendingEnvelope.pending)
        let staged = await sink.staged
        #expect(staged.count == 1)
        #expect(staged.first?.correlationID == pendingEnvelope.completionToken)

        held.open()
        _ = try await Fixtures.settledTerminal(of: pendingEnvelope.completionToken, in: runPlane)
    }

    // MARK: - One terminal event on each path

    @Test("a background run that beats after it returns settles one time, with one terminal event")
    func beatingBackgroundRunSettlesOnce() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.HeartbeatTool(beats: Self.beatingRunBeats, interval: Self.heartbeatInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)

        // The run posts its own progress after it returns, and still gets one
        // terminal event when it settles.
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "heartbeat done")

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.contains { $0.kind == .progress && $0.detail.hasPrefix("beat ") })
    }

    @Test("the timeout of a background run settles it with outcome timedOut and one terminal event")
    func timeoutExpiryOnBackgroundRun() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.SleepingTool(), timeout: Fixtures.shortInterval)

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.outcome == .timedOut)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
    }

    @Test("a cancel of a background run settles it with outcome cancelled and one terminal event")
    func cancellingBackgroundRunYieldsOneCancelledTerminal() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.SleepingTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        let cancelResult = await harness.runPlane.cancel(completionToken: envelope.completionToken)
        #expect(cancelResult == .reported(.cancelled))

        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.outcome == .cancelled)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .cancelled)
    }

    @Test("the cooperative flag of a cancelled run reaches the tool through ToolContext.isCancelled")
    func cancellationFlagReachesTool() async throws {
        let witness = Fixtures.CancellationWitness()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.CancellationFlagPollingTool(witness: witness))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        let cancelResult = await harness.runPlane.cancel(completionToken: envelope.completionToken)
        #expect(cancelResult == .reported(.cancelled))

        // The tool reads only the flag, and returns normally when it is set:
        // an honest success.
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == "observed cancellation")
        #expect(terminal.outcome == .succeeded)
        #expect(await witness.observed)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
    }

    // MARK: - Attachments

    @Test("attachments made after the run returns still reach the settlement of that run, in call order")
    func lateAttachmentsReachTheSettlement() async throws {
        let gate = RunLatch()
        let sink = Fixtures.RecordingSink()
        let arguments = MountArguments(value: "late")
        let run = Fixtures.toolRun(wrapping: Fixtures.GatedAttachingTool(gate: gate), arguments: arguments, sink: sink)

        await run.open()
        // The body runs behind the return, as a background run does.
        let settling = Task { await run.execute(arguments: arguments) }
        // The second record lands only after the gate opens.
        gate.open()
        let settlement = await settling.value

        #expect(settlement.attachments == Fixtures.attachmentsInCallOrder)
        #expect(try settlement.result.get() == "attached late: late")
    }

    @Test("attachments never reach the envelope, the terminal event, or an event of a background call")
    func attachmentsStayOutOfTheModelFacingOutput() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.GatedAttachingTool(gate: gate))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!Fixtures.isAttachmentMentioned(in: rendered))

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == "attached late: x")

        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(!events.contains { Fixtures.isAttachmentMentioned(in: $0.detail) })
    }

    // MARK: - The run-plane list

    @Test("the progress of a background run goes into the run-plane list")
    func backgroundRunProgressFeedsStatus() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.HeartbeatTool(beats: Self.snapshotRunBeats, interval: Self.heartbeatInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        // Poll, with a bound, until a beat is in the row of the run.
        let observedDetail = try await Fixtures.poll {
            await harness.runPlane.backgroundRuns().first?.latestProgressDetail
        }
        #expect(observedDetail?.hasPrefix("beat ") == true)

        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
    }
}
