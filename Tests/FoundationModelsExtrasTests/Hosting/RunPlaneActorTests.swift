@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the ``RunPlane`` actor: tracked background runs (start, list,
/// wait, cancel), the pending elicitations, and the sweep.
@Suite("Run plane actor: background runs, elicitations and the sweep")
struct RunPlaneActorTests {
    // MARK: - start / backgroundRuns / wait

    @Test("start lists the run in backgroundRuns(), wait() returns its terminal event, and a settled run leaves backgroundRuns()")
    func startListingAndWaitLifecycle() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch, detailOnSettle: "exit 0")

        let pending = await runPlane.backgroundRuns()
        #expect(pending.count == 1)
        #expect(pending.first?.completionToken == token)
        #expect(pending.first?.tool == FakeRun.tool)
        #expect(pending.first?.op == FakeRun.op)
        #expect(pending.first?.kind == .swiftTask)
        #expect(pending.first?.latestProgressDetail == nil)

        await runPlane.updateProgress(completionToken: token, detail: "50%")
        #expect(await runPlane.backgroundRuns().first?.latestProgressDetail == "50%")

        latch.open()
        let result = await runPlane.wait(completionToken: token, seconds: 5)
        let terminal = try #require(result.settledTerminal, "expected .settled, got \(result)")
        #expect(terminal.correlationID == token)
        #expect(terminal.kind == .completed)
        #expect(terminal.detail == "exit 0")
        #expect(terminal.outcome == .succeeded)

        #expect(await runPlane.backgroundRuns().isEmpty)
    }

    @Test("wait() on a run that never settles elapses its deadline and leaves the run tracked")
    func waitDeadlineElapses() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)

        let result = await runPlane.wait(completionToken: token, seconds: 0.05)
        #expect(result == .deadlineElapsed)
        #expect(await runPlane.backgroundRuns().count == 1)

        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: 5)
    }

    @Test("wait() clamps a deadline from outside and does not trap", arguments: [-1.0, 0.0, Double.nan])
    func waitClampsUntrustedSeconds(seconds: Double) async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)

        // A deadline that is not positive, or not finite, elapses at once and
        // leaves the run tracked.
        let result = await runPlane.wait(completionToken: token, seconds: seconds)
        #expect(result == .deadlineElapsed)
        #expect(await runPlane.backgroundRuns().count == 1)

        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: 5)
    }

    // MARK: - Deadlines as given

    /// Nanoseconds in one second.
    private static let nanosecondsPerSecond: Double = 1_000_000_000

    /// A deadline longer than one day.
    private static let longerThanOneDaySeconds: Double = 90_000

    /// The time after which the fake run of the no-deadline test settles.
    private static let settleAfterSeconds: Double = 2

    /// A deadline that elapses before the fake run of the no-deadline test
    /// settles.
    private static let shorterDeadlineSeconds: Double = 1

    @Test(
        "boundedNanoseconds gives UInt64.max for a deadline whose nanoseconds UInt64 cannot hold",
        arguments: [Double.infinity, Double.greatestFiniteMagnitude]
    )
    func boundedNanosecondsSaturatesAtTheTypeLimit(seconds: Double) {
        #expect(RunPlane.boundedNanoseconds(clamping: seconds) == UInt64.max)
    }

    @Test("boundedNanoseconds converts a deadline longer than one day as is")
    func boundedNanosecondsConvertsALongDeadlineAsIs() {
        #expect(
            RunPlane.boundedNanoseconds(clamping: Self.longerThanOneDaySeconds)
                == UInt64(Self.longerThanOneDaySeconds * Self.nanosecondsPerSecond)
        )
    }

    @Test("boundedNanoseconds gives zero for NaN and for a negative deadline", arguments: [-1.0, -Double.infinity, Double.nan])
    func boundedNanosecondsFloorsAtZero(seconds: Double) {
        #expect(RunPlane.boundedNanoseconds(clamping: seconds) == 0)
    }

    @Test("wait() with no deadline returns the settlement; a shorter named deadline elapses first")
    func waitWithNoDeadlineReturnsTheSettlement() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)
        let settleAfter = UInt64(Self.settleAfterSeconds * Self.nanosecondsPerSecond)
        let opener = Task {
            try await Task.sleep(nanoseconds: settleAfter)
            latch.open()
        }

        #expect(await runPlane.wait(completionToken: token, seconds: Self.shorterDeadlineSeconds) == .deadlineElapsed)
        let result = await runPlane.wait(completionToken: token, seconds: nil)
        let terminal = try #require(result.settledTerminal, "expected .settled, got \(result)")
        #expect(terminal.correlationID == token)
        try await opener.value
    }

    @Test("a cancelled wait() with no deadline returns .cancelled and leaves the run tracked")
    func cancelledWaitWithNoDeadlineReturnsCancelled() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)

        let waiting = Task { await runPlane.wait(completionToken: token, seconds: nil) }
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        #expect(await runPlane.backgroundRuns().count == 1)

        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: nil)
    }

    /// The number of waits that the waiter-count tests make on one open run.
    private static let repeatedWaitCount = 1_000

    @Test("many waits that end at their deadline leave no waiter on the open run, and a later wait still gets the settlement")
    func deadlineWaitsLeaveNoWaiters() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)

        for _ in 0..<Self.repeatedWaitCount {
            #expect(await runPlane.wait(completionToken: token, seconds: 0) == .deadlineElapsed)
        }
        #expect(await runPlane.waiterCount(completionToken: token) == 0)

        latch.open()
        let result = await runPlane.wait(completionToken: token, seconds: nil)
        let terminal = try #require(result.settledTerminal, "expected .settled, got \(result)")
        #expect(terminal.correlationID == token)
    }

    @Test("many waits that end at a cancel leave no waiter on the open run")
    func cancelledWaitsLeaveNoWaiters() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)

        for _ in 0..<Self.repeatedWaitCount {
            let waiting = Task { await runPlane.wait(completionToken: token, seconds: nil) }
            waiting.cancel()
            #expect(await waiting.value == .cancelled)
        }
        #expect(await runPlane.waiterCount(completionToken: token) == 0)

        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: nil)
    }

    @Test("a settled run answers wait() at once, also with a deadline clamped to zero")
    func settledRunResolvesWaitDespiteZeroDeadline() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)
        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: 5)

        let result = await runPlane.wait(completionToken: token, seconds: -1)
        let terminal = try #require(result.settledTerminal, "expected .settled, got \(result)")
        #expect(terminal.correlationID == token)
    }

    // MARK: - cancel

    @Test("cancel() runs the canceler, reports its outcome, and a wait() at the same time gets the cancelled terminal event")
    func cancelWhileWaiting() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)

        let waiting = Task { await runPlane.wait(completionToken: token, seconds: 5) }
        let cancelResult = await runPlane.cancel(completionToken: token)
        #expect(cancelResult == .reported(.cancelled))

        let waited = await waiting.value
        let terminal = try #require(waited.settledTerminal, "expected .settled, got \(waited)")
        #expect(terminal.correlationID == token)
        #expect(terminal.outcome == .cancelled)
    }

    @Test("cancel() reports the outcome of the canceler, and does not guess")
    func cancelReportsCancelerOutcomeVerbatim() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch, cancelerOutcome: .stopped)

        let cancelResult = await runPlane.cancel(completionToken: token)
        #expect(cancelResult == .reported(.stopped))

        _ = await runPlane.wait(completionToken: token, seconds: 5)
    }

    @Test("cancel() on a settled run reports .alreadySettled with its terminal event, never .unknownToken")
    func cancelOnSettledRunReportsAlreadySettled() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch, detailOnSettle: "exit 0")
        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: 5)

        let cancelResult = await runPlane.cancel(completionToken: token)
        let terminal = try #require(cancelResult.alreadySettledTerminal, "expected .alreadySettled, got \(cancelResult)")
        #expect(terminal.correlationID == token)
        #expect(terminal.outcome == .succeeded)
    }

    // MARK: - start refuses a token in use

    @Test("start() with a token in use refuses the new run and leaves the first run as it is")
    func startRefusesDuplicateToken() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)

        let refused = await runPlane.start(
            tool: FakeRun.tool,
            op: FakeRun.op,
            kind: .swiftTask,
            completionToken: token,
            canceler: { .cancelled },
            body: {
                OperationEvent(
                    tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .completed,
                    detail: "refused", outcome: .succeeded
                )
            }
        )
        #expect(refused == .duplicateToken)
        // The first run is still the only background run.
        #expect(await runPlane.backgroundRuns().count == 1)

        latch.open()
        let result = await runPlane.wait(completionToken: token, seconds: 5)
        let terminal = try #require(result.settledTerminal, "expected .settled, got \(result)")
        // The terminal event of the first run won, not the refused run.
        #expect(terminal.detail == "done")
    }

    // MARK: - Settled terminal events stay for the session

    /// The number of runs that the retention test settles.
    private static let settlementsPastTheRemovedBound = 129

    @Test("the run plane keeps each settled terminal event: wait() and cancel() on the first token answer with its terminal after many settlements")
    func settledTerminalEventsAreKeptForTheSessionLifetime() async throws {
        let runPlane = RunPlane()
        let firstLatch = RunLatch()
        let firstToken = await FakeRun.start(on: runPlane, latch: firstLatch, detailOnSettle: "first")
        firstLatch.open()
        let firstSettlement = await runPlane.wait(completionToken: firstToken, seconds: 5)
        let firstTerminal = try #require(firstSettlement.settledTerminal, "expected .settled for the first run, got \(firstSettlement)")
        #expect(firstTerminal.correlationID == firstToken)
        #expect(firstTerminal.detail == "first")
        for _ in 1..<Self.settlementsPastTheRemovedBound {
            let latch = RunLatch()
            let token = await FakeRun.start(on: runPlane, latch: latch)
            latch.open()
            _ = await runPlane.wait(completionToken: token, seconds: 5)
        }

        #expect(await runPlane.wait(completionToken: firstToken, seconds: 5) == .settled(firstTerminal))
        #expect(await runPlane.cancel(completionToken: firstToken) == .alreadySettled(firstTerminal))
    }

    // MARK: - The settlement observer

    /// Keeps each terminal event that the run plane gives it.
    private actor RecordingSettlementObserver: BackgroundRunSettlementObserver {
        /// Each terminal event, in delivery order.
        private(set) var settledTerminals: [OperationEvent] = []

        func deliver(settledTerminal terminal: OperationEvent) async {
            settledTerminals.append(terminal)
        }
    }

    /// The detail of a swept run that ends after the sweep.
    private static let lateBodyDetail = "finished after the sweep"

    /// The time that a test waits after a late settlement before it reads
    /// the observer, so that a wrong delivery has time to occur.
    private static let forwardingGraceNanoseconds: UInt64 = 200_000_000

    @Test("the run plane gives the terminal event of a run that settled by itself to the observer one time")
    func startForwardsTheSettledTerminalOnce() async {
        let runPlane = RunPlane()
        let observer = RecordingSettlementObserver()
        await runPlane.attach(settlementObserver: observer)
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch, detailOnSettle: "exit 0")

        latch.open()
        let waited = await runPlane.wait(completionToken: token, seconds: 5)
        #expect(
            await BoundedWait.conditionReached("the observer receiving the settled terminal") {
                await observer.settledTerminals.count == 1
            })

        // The observer gets the same event that wait returned.
        let forwarded = await observer.settledTerminals
        #expect(forwarded.first.map(WaitOutcome.settled) == waited)
        #expect(forwarded.first?.correlationID == token)
        #expect(forwarded.first?.detail == "exit 0")
    }

    @Test("the run plane gives nothing to the observer for a run that the sweep removed")
    func startForwardsNothingForASweptRun() async throws {
        let runPlane = RunPlane()
        let observer = RecordingSettlementObserver()
        await runPlane.attach(settlementObserver: observer)
        let latch = RunLatch()
        let bodyEnded = RunLatch()
        let token = RunPlane.makeCompletionToken()
        // A process run: the canceler only reports, so the body waits on the
        // latch through the sweep and ends only when the test opens it.
        await runPlane.start(
            tool: FakeRun.tool,
            op: FakeRun.op,
            kind: .process,
            completionToken: token,
            canceler: { .cancelled },
            body: {
                await latch.waitUntilOpen()
                bodyEnded.open()
                return OperationEvent(
                    tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .completed,
                    detail: Self.lateBodyDetail, outcome: .succeeded
                )
            }
        )

        let swept = await runPlane.sweep()
        #expect(swept.map(\.correlationID) == [token])

        // The body ends after the sweep. The run plane does not track the run
        // now, so it drops the late terminal event, and the observer gets
        // nothing.
        latch.open()
        await bodyEnded.waitUntilOpen()
        try await Task.sleep(nanoseconds: Self.forwardingGraceNanoseconds)
        #expect(await observer.settledTerminals.isEmpty)

        // wait still reports the swept terminal event.
        let terminal = try #require(await runPlane.wait(completionToken: token, seconds: 5).settledTerminal)
        #expect(terminal.outcome == .cancelled)
    }

    // MARK: - Unknown ids

    @Test("an operation on an unknown completionToken does nothing, and tells so")
    func unknownCompletionTokenIsNoOp() async {
        let runPlane = RunPlane()
        let unknown = RunPlane.makeCompletionToken()

        #expect(await runPlane.cancel(completionToken: unknown) == .unknownToken)
        #expect(await runPlane.wait(completionToken: unknown, seconds: 5) == .unknownToken)
        await runPlane.updateProgress(completionToken: unknown, detail: "ignored")
        #expect(await runPlane.backgroundRuns().isEmpty)
    }

    @Test("an unknown elicitationId, or one that is closed, does nothing")
    func unknownElicitationIdIsNoOp() async {
        let runPlane = RunPlane()
        let unknown = ULID()

        #expect(await runPlane.respond(elicitationId: unknown, .decline) == .noPendingElicitation)
        #expect(await runPlane.complete(elicitationId: unknown) == .noPendingElicitation)
    }

    // MARK: - Pending elicitations

    /// A form request with `elicitationId`.
    private static func formRequest(elicitationId: ULID) -> ElicitationRequest {
        ElicitationRequest(
            message: "name?",
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(properties: ["name": .string(ElicitationStringSchema())])
        )
    }

    /// Waits until `elicitationId` is the only pending elicitation.
    private static func isPending(_ elicitationId: ULID, on runPlane: RunPlane) async -> Bool {
        await BoundedWait.conditionReached("the elicitation \(elicitationId) pending") {
            await runPlane.pendingElicitationIds() == [elicitationId]
        }
    }

    @Test("a form elicitation resumes on respond(), and a second respond does nothing")
    func formElicitationDeliversAnswer() async throws {
        let runPlane = RunPlane()
        let elicitationId = ULID()
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(elicitationId)") {
            await runPlane.awaitAnswer(to: Self.formRequest(elicitationId: elicitationId))
        }
        #expect(await Self.isPending(elicitationId, on: runPlane))

        let answer = ElicitationResponse.accept(content: ["name": .string("Ada")])
        #expect(await runPlane.respond(elicitationId: elicitationId, answer) == .delivered)
        #expect(try await answering.deliveredAnswer() == answer)
        #expect(await runPlane.pendingElicitationIds().isEmpty)
        #expect(await runPlane.respond(elicitationId: elicitationId, .decline) == .noPendingElicitation)
    }

    @Test("a URL elicitation stays open after accept until complete(elicitationId:)")
    func urlElicitationStaysOpenPastAccept() async throws {
        let runPlane = RunPlane()
        let elicitationId = ULID()
        let request = ElicitationRequest(
            message: "open this",
            elicitationId: elicitationId,
            url: try #require(URL(string: "https://example.com/flow"))
        )
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(elicitationId)") {
            await runPlane.awaitAnswer(to: request)
        }
        #expect(await Self.isPending(elicitationId, on: runPlane))

        #expect(await runPlane.respond(elicitationId: elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        // The accept alone does not resume the run: the entry stays open.
        #expect(await runPlane.pendingElicitationIds() == [elicitationId])

        #expect(await runPlane.complete(elicitationId: elicitationId) == .completed)
        #expect(try await answering.deliveredAnswer() == .accept(content: nil))
        #expect(await runPlane.pendingElicitationIds().isEmpty)
        #expect(await runPlane.complete(elicitationId: elicitationId) == .noPendingElicitation)
    }

    @Test("a URL decline resumes at once, with no wait for the completion")
    func urlElicitationDeclineResumesImmediately() async throws {
        let runPlane = RunPlane()
        let elicitationId = ULID()
        let request = ElicitationRequest(
            message: "open this",
            elicitationId: elicitationId,
            url: try #require(URL(string: "https://example.com/flow"))
        )
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(elicitationId)") {
            await runPlane.awaitAnswer(to: request)
        }
        #expect(await Self.isPending(elicitationId, on: runPlane))

        #expect(await runPlane.respond(elicitationId: elicitationId, .decline) == .delivered)
        #expect(try await answering.deliveredAnswer() == .decline)
        #expect(await runPlane.pendingElicitationIds().isEmpty)
    }

    // MARK: - The sweep

    @Test("sweep() runs each canceler, gives one terminal event for each run, and rejects each pending elicitation")
    func sweepCancelsRunsAndRejectsElicitations() async throws {
        let runPlane = RunPlane()
        let cancels = Recorder<String>()
        let latch = RunLatch()
        let tokenA = await FakeRun.start(on: runPlane, latch: latch, kind: .process, cancels: cancels)
        let tokenB = await FakeRun.start(on: runPlane, latch: latch, kind: .process, cancels: cancels)
        let elicitationId = ULID()
        let rejected = AnswerDrivenRun(waitingFor: "the elicitation \(elicitationId) that the sweep rejects") {
            await runPlane.awaitAnswer(to: Self.formRequest(elicitationId: elicitationId))
        }
        #expect(await Self.isPending(elicitationId, on: runPlane))

        let terminals = await runPlane.sweep()

        #expect(cancels.values == [tokenA, tokenB])
        #expect(terminals.map(\.correlationID) == [tokenA, tokenB])
        #expect(terminals.allSatisfy { $0.kind == .completed && $0.outcome == .cancelled })
        #expect(await runPlane.backgroundRuns().isEmpty)
        #expect(await runPlane.pendingElicitationIds().isEmpty)
        #expect(try await rejected.deliveredAnswer() == .cancel)
        // A swept token reports its terminal event to wait().
        #expect(await runPlane.wait(completionToken: tokenA, seconds: 5).settledTerminal?.correlationID == tokenA)
        latch.open()
    }

    @Test("a second sweep at the same time returns nothing, and runs no canceler a second time")
    func concurrentSweepRunsEachCancelerOnce() async {
        let runPlane = RunPlane()
        let cancels = Recorder<String>()
        let latch = RunLatch()
        _ = await FakeRun.start(on: runPlane, latch: latch, kind: .process, cancels: cancels)
        _ = await FakeRun.start(on: runPlane, latch: latch, kind: .process, cancels: cancels)

        async let first = runPlane.sweep()
        async let second = runPlane.sweep()
        let (firstTerminals, secondTerminals) = await (first, second)
        let third = await runPlane.sweep()

        #expect(cancels.values.count == 2)
        #expect(firstTerminals.count + secondTerminals.count + third.count == 2)
        latch.open()
    }

    // MARK: - The join of the run bodies

    @Test("joinRunBodies() returns only after the body of a swept run ended", .timeLimit(.minutes(1)))
    func joinWaitsForTheBodyOfASweptRun() async {
        let runPlane = RunPlane()
        let steps = Recorder<String>()
        let token = RunPlane.makeCompletionToken()
        await runPlane.start(
            tool: FakeRun.tool, op: FakeRun.op, kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            // The body sees the cancel, and then takes some turns to unwind.
            try? await Task.sleep(for: .seconds(3600))
            for _ in 0..<Self.unwindTurns {
                await Task.yield()
            }
            steps.append("body ended")
            return OperationEvent(
                tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .completed, detail: "",
                outcome: .cancelled)
        }

        _ = await runPlane.sweep()
        await runPlane.joinRunBodies()
        steps.append("joined")

        #expect(steps.values == ["body ended", "joined"])
    }

    @Test("joinRunBodies() returns at once when no run body runs", .timeLimit(.minutes(1)))
    func joinWithNoBodyReturns() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)
        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: nil)

        await runPlane.joinRunBodies()
        await RunPlane().joinRunBodies()
    }

    /// The turns that the body of a swept run takes to unwind.
    private static let unwindTurns = 100
}
