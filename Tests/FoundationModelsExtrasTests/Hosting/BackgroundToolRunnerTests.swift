@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises ``BackgroundToolRunner``: the settle period of each call, the
/// output or the envelope of each call, the run on the run plane, the events,
/// the timeout of a background run, the canceler, the run-plane list, and one
/// `.completed` for a natural settle, a cancel and a timeout.
@Suite("BackgroundToolRunner: start the body, answer inside the grace or with the pending envelope")
struct BackgroundToolRunnerTests {
    private typealias Fixtures = MountFixtures

    /// The number of heartbeats of a run that beats after the handle returns.
    private static let beatingRunBeats = 20

    /// The number of heartbeats of the tool of the run-plane list test.
    private static let snapshotRunBeats = 40

    /// The pause between two heartbeats.
    private static let heartbeatInterval: TimeInterval = 0.05

    /// A settle period that a test configures on a site, and that a run
    /// that stays on its gate passes.
    private static let configuredSiteGrace: TimeInterval = 0.25

    /// A background tool that states no grace and returns at once.
    private struct NoGraceTool: Tool, BackgroundTool {
        let name = "no_grace_tool"
        let description = "states no grace"

        func call(arguments: MountArguments) async throws -> String {
            arguments.value
        }
    }

    /// The seconds from `start` to now.
    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let parts = (ContinuousClock.now - start).components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    // MARK: - The handle of each call

    @Test("a background tool whose body ends at once still returns a PendingRunEnvelope at grace 0: the run is tracked before the body runs")
    func instantBodyStillReturnsEnvelope() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.TrackedAtStartTool(), inlineSettleGrace: Fixtures.pendingAtOnceGrace)

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
        #expect(envelope.isPending)
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
        #expect(envelope.isPending)
        #expect(envelope.next == Fixtures.CollectSentenceTool.collectInstruction(forCompletionToken: envelope.completionToken))
        #expect(rendered == PendingRunEnvelope(completionToken: envelope.completionToken, next: envelope.next).rendered)

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == "collected: own sentence")
    }

    // MARK: - The settle period of each call

    @Test("a tool that states no grace reads the settle period that its mount site configured")
    func defaultGraceIsTheConfiguredSiteValue() {
        let tool = NoGraceTool()

        let configured = InlineSettle.$configuredGrace.withValue(Self.configuredSiteGrace) {
            tool.inlineSettleGrace
        }

        #expect(configured == Self.configuredSiteGrace)
    }

    @Test("a mount site that states no settle period uses ToolMount.defaultInlineSettleGrace, and so does a tool that states none")
    func defaultSiteGraceIsTheOneConstant() {
        let site = MountSite(sessionID: ULID(), runPlane: RunPlane(), sink: Fixtures.RecordingSink())

        #expect(site.inlineSettleGrace == ToolMount.defaultInlineSettleGrace)
        let read = InlineSettle.$configuredGrace.withValue(site.inlineSettleGrace) { NoGraceTool().inlineSettleGrace }
        #expect(read == ToolMount.defaultInlineSettleGrace)
        #expect(NoGraceTool().inlineSettleGrace == ToolMount.defaultInlineSettleGrace)
    }

    @Test("a mount site turns a negative settle period into 0")
    func negativeSiteGraceActsAsZero() {
        let site = MountSite(sessionID: ULID(), runPlane: RunPlane(), sink: Fixtures.RecordingSink(), inlineSettleGrace: -1)

        #expect(site.inlineSettleGrace == 0)
    }

    @Test("a tool that states no grace answers with its own output on a site with a generous grace, and with the envelope on a site with grace 0")
    func toolWithNoGraceFollowsTheSite() async throws {
        let gate = RunLatch()
        gate.open()
        let generous = Fixtures.backgroundHarness(
            wrapping: Fixtures.SiteGraceTool(gate: gate), inlineSettleGrace: Fixtures.generousInterval)
        let atOnce = Fixtures.backgroundHarness(
            wrapping: Fixtures.SiteGraceTool(gate: gate), inlineSettleGrace: Fixtures.pendingAtOnceGrace)

        let inline = try await generous.mounted.call(arguments: MountArguments(value: "site"))
        let pending = try await atOnce.mounted.call(arguments: MountArguments(value: "site"))

        #expect(inline == Fixtures.SiteGraceTool.output(for: "site"))
        let envelope = try Fixtures.decodeEnvelope(pending)
        #expect(envelope.isPending)
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: atOnce.runPlane)
    }

    @Test("a tool that states no grace on a site that takes the default settles a fast run inline")
    func defaultSiteGraceSettlesAFastRunInline() async throws {
        let runPlane = RunPlane()
        let site = MountSite(sessionID: ULID(), runPlane: runPlane, sink: Fixtures.RecordingSink())
        let runner = BackgroundToolRunner(wrapping: Fixtures.FastTool(), site: site, timeout: nil)

        let rendered = try await runner.call(arguments: MountArguments(value: "default"))

        #expect(rendered == "fast: default")
        #expect(await runPlane.backgroundRuns().isEmpty)
    }

    @Test("the grace that a tool states wins over the settle period of its site, in both directions")
    func statedGraceWinsOverTheSite() async throws {
        let gate = RunLatch()
        gate.open()
        // The site answers at once, but the tool waits.
        let waitingTool = Fixtures.backgroundHarness(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval),
            inlineSettleGrace: Fixtures.pendingAtOnceGrace)
        // The site waits, but the tool answers at once.
        let atOnceTool = Fixtures.backgroundHarness(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: 0), inlineSettleGrace: Fixtures.generousInterval)

        let inline = try await waitingTool.mounted.call(arguments: MountArguments(value: "tool"))
        let pending = try await atOnceTool.mounted.call(arguments: MountArguments(value: "tool"))

        #expect(inline == Fixtures.InlineGraceTool.output(for: "tool"))
        let envelope = try Fixtures.decodeEnvelope(pending)
        #expect(envelope.isPending)
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: atOnceTool.runPlane)
    }

    @Test("grace 0 answers with the pending envelope at once, also for a run that ends at once")
    func zeroGraceAnswersPendingAtOnce() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.FastTool(), inlineSettleGrace: 0)

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "zero"))

        let envelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: rendered))
        #expect(envelope.pending)
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == "fast: zero")
    }

    // MARK: - A run that ends inside the grace

    @Test("a run that ends inside the grace answers with the output of the tool, not an envelope, and the run plane still reports that result")
    func runSettlingInsideTheGraceAnswersWithItsOwnOutput() async throws {
        let gate = RunLatch()
        // Open already, so the body returns when it starts, before the grace.
        gate.open()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "now"))

        #expect(rendered == Fixtures.InlineGraceTool.output(for: "now"))
        #expect(!PendingRunEnvelope.isRendered(text: rendered))

        // The run settled by itself, so the run plane holds the same result.
        let token = try #require(await harness.runPlane.settledRunTokens().first)
        let terminal = try await Fixtures.settledTerminal(of: token, in: harness.runPlane)
        #expect(terminal.detail == Fixtures.InlineGraceTool.output(for: "now"))
        #expect(terminal.outcome == .succeeded)

        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
    }

    @Test("a run that throws inside the grace rethrows the error of the tool")
    func runThrowingInsideTheGraceRethrowsTheToolError() async throws {
        let gate = RunLatch()
        gate.open()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.InlineThrowingTool(gate: gate, grace: Fixtures.generousInterval))

        await #expect(throws: Fixtures.FixtureError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "fail"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .failed)
    }

    @Test("an inline result leaves nothing staged for a later prompt, and a pending run still stages its progress")
    func inlineResultWithdrawsWhatTheRunStaged() async throws {
        let runPlane = RunPlane()
        let sink = Fixtures.StagingSink()
        let site = Fixtures.site(runPlane: runPlane, sink: sink, inlineSettleGrace: Fixtures.pendingAtOnceGrace)
        let gate = RunLatch()
        gate.open()
        let inline = BackgroundToolRunner(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval), site: site, timeout: nil
        )

        let rendered = try await inline.call(arguments: MountArguments(value: "inline"))

        #expect(rendered == Fixtures.InlineGraceTool.output(for: "inline"))
        #expect(await sink.staged.isEmpty)

        // The same sink still stages a run whose result the model does not
        // have, so only a run that answers inline takes its events back.
        let held = RunLatch()
        let pendingRun = BackgroundToolRunner(wrapping: Fixtures.GatedTool(gate: held), site: site, timeout: nil)

        let pendingRendered = try await pendingRun.call(arguments: MountArguments(value: "held"))

        let pendingEnvelope = try Fixtures.decodeEnvelope(pendingRendered)
        #expect(pendingEnvelope.isPending)
        let staged = await sink.staged
        #expect(staged.count == 1)
        #expect(staged.first?.correlationID == pendingEnvelope.completionToken)

        held.open()
        _ = try await Fixtures.settledTerminal(of: pendingEnvelope.completionToken, in: runPlane)
    }

    @Test("a run that throws inside the grace also takes back its staged events")
    func inlineErrorWithdrawsWhatTheRunStaged() async throws {
        let sink = Fixtures.StagingSink()
        let site = Fixtures.site(runPlane: RunPlane(), sink: sink, inlineSettleGrace: Fixtures.pendingAtOnceGrace)
        let gate = RunLatch()
        gate.open()
        let runner = BackgroundToolRunner(
            wrapping: Fixtures.InlineThrowingTool(gate: gate, grace: Fixtures.generousInterval), site: site, timeout: nil)

        await #expect(throws: Fixtures.FixtureError.self) {
            _ = try await runner.call(arguments: MountArguments(value: "fail"))
        }

        #expect(await sink.staged.isEmpty)
    }

    // MARK: - A run that continues past the grace

    @Test("a run that continues past the configured grace answers with the pending envelope, and later settles with exactly one terminal event")
    func runStillGoingWhenTheGraceElapsesAnswersPending() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.SiteGraceTool(gate: gate), inlineSettleGrace: Self.configuredSiteGrace)
        let start = ContinuousClock.now

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "later"))

        // The call waited for the grace of the site before it answered.
        #expect(Self.seconds(since: start) >= Self.configuredSiteGrace * 0.9)
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.isPending)
        #expect(envelope.next == PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: envelope.completionToken))
        #expect(rendered == PendingRunEnvelope(completionToken: envelope.completionToken).rendered)

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == Fixtures.SiteGraceTool.output(for: "later"))
        #expect(terminal.outcome == .succeeded)
        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.map(\.kind) == [.progress, .completed])
    }

    // MARK: - One terminal event on each path

    @Test("a background run that beats after it returns settles one time, with one terminal event")
    func beatingBackgroundRunSettlesOnce() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.HeartbeatTool(beats: Self.beatingRunBeats, interval: Self.heartbeatInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.isPending)

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
        #expect(await witness.isObserved)

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
