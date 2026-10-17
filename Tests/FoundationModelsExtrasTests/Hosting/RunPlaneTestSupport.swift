@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// A latch that the body of a test run waits on until the test opens it.
typealias RunLatch = Promise<Void>

extension Promise where Value == Void {
    /// A new latch that is not open. A test file with a plain import calls
    /// this, because the initializer of `Promise` is internal.
    ///
    /// - Returns: The latch.
    static func closed() -> RunLatch {
        RunLatch()
    }

    /// Opens the latch. Each body that waits on it resumes.
    func open() {
        fulfill(())
    }

    /// Waits until the latch is open. Returns at once when it is open.
    func waitUntilOpen() async {
        await value
    }
}

extension WaitOutcome {
    /// The terminal event of a settled run, or `nil` for each other outcome.
    var settledTerminal: OperationEvent? {
        guard case .settled(let terminal) = self else { return nil }
        return terminal
    }
}

extension CancelOutcome {
    /// The terminal event of a run that settled before the cancel, or `nil`
    /// for each other outcome.
    var alreadySettledTerminal: OperationEvent? {
        guard case .alreadySettled(let terminal) = self else { return nil }
        return terminal
    }

    /// The outcome that the canceler of the run reported, or `nil` for each
    /// other outcome.
    var reportedOutcome: OperationOutcome? {
        guard case .reported(let outcome) = self else { return nil }
        return outcome
    }
}

/// A sink that drops each event, for a test that reads the run plane and not
/// the events.
struct DiscardingOperationEventSink: OperationEventSink {
    /// Drops `event`.
    ///
    /// - Parameter event: The event to drop.
    func post(event: OperationEvent) async {}
}

/// A fake background run: its body waits on a latch, and its canceler reports
/// an outcome that the test chooses.
enum FakeRun {
    /// The tool name of each fake run.
    static let tool = "fake"

    /// The op of each fake run.
    static let op = "run task"

    /// Starts a fake run of `kind` on `runPlane`.
    ///
    /// The body waits on `latch`, then returns a terminal event with
    /// `detailOnSettle`. The outcome is ``OperationOutcome/cancelled`` when
    /// the canceler ran before the body ended, and
    /// ``OperationOutcome/succeeded`` when it did not.
    ///
    /// The canceler reports `cancelerOutcome`. What it does first depends on
    /// `kind`:
    /// - ``RunKind/swiftTask``: a cancel is cooperative, so the canceler opens
    ///   `latch` and the body ends.
    /// - ``RunKind/process``: the kill belongs to the capability, so the
    ///   canceler only reports. The body ends when the test opens `latch`.
    ///
    /// - Parameters:
    ///   - runPlane: The run plane that tracks the run.
    ///   - latch: The latch that the body waits on.
    ///   - kind: The kind of work of the run.
    ///   - detailOnSettle: The detail of the terminal event.
    ///   - cancelerOutcome: The outcome that the canceler reports.
    ///   - cancels: Gets the token of the run each time its canceler runs.
    /// - Returns: The completion token of the run.
    static func start(
        on runPlane: RunPlane,
        latch: RunLatch,
        kind: RunKind = .swiftTask,
        detailOnSettle: String = "done",
        cancelerOutcome: OperationOutcome = .cancelled,
        cancels: Recorder<String>? = nil
    ) async -> String {
        let token = RunPlane.makeCompletionToken()
        let cancelRequests = Recorder<String>()
        await runPlane.start(
            tool: tool,
            op: op,
            kind: kind,
            completionToken: token,
            canceler: {
                cancels?.append(token)
                if kind == .swiftTask {
                    cancelRequests.append(token)
                    latch.open()
                }
                return cancelerOutcome
            },
            body: {
                await latch.waitUntilOpen()
                return terminalEvent(
                    token: token,
                    outcome: cancelRequests.values.isEmpty ? .succeeded : .cancelled,
                    detail: detailOnSettle
                )
            }
        )
        return token
    }

    /// Makes the terminal event of a fake run: a completed event with the
    /// tool and the op of each fake run.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - outcome: The outcome of the event, or `nil` for no outcome.
    ///   - detail: The detail of the event. The default is empty.
    /// - Returns: The terminal event.
    static func terminalEvent(token: String, outcome: OperationOutcome?, detail: String = "") -> OperationEvent {
        OperationEvent.terminal(tool: tool, op: op, token: token, outcome: outcome, detail: detail)
    }
}

extension OperationEvent {
    /// Makes a terminal event: an event of the kind
    /// ``OperationEventKind/completed``. Each test that needs a terminal event
    /// calls this function, so the shape of the event occurs in one place.
    ///
    /// - Parameters:
    ///   - tool: The tool name. The default is empty, for a test where the
    ///     context of the run stamps the tool name.
    ///   - op: The op. The default is empty, for a test where the context of
    ///     the run stamps the op.
    ///   - token: The completion token of the run, as the correlation ID. The
    ///     default is empty, for a test where the context of the run stamps
    ///     the token.
    ///   - outcome: The outcome of the event, or `nil` for no outcome.
    ///   - detail: The detail of the event. The default is empty.
    /// - Returns: The terminal event.
    static func terminal(
        tool: String = "", op: String = "", token: String = "", outcome: OperationOutcome?, detail: String = ""
    ) -> OperationEvent {
        OperationEvent(tool: tool, op: op, correlationID: token, kind: .completed, detail: detail, outcome: outcome)
    }
}

extension ManualRunClock {
    /// Waits until at least `count` waits are open on this clock, or until
    /// `ended` ends first. A clock that never gets the waits then does not
    /// hang the test: the test reads ``sleeperCount`` and fails.
    ///
    /// - Parameters:
    ///   - count: The number of waits.
    ///   - ended: The wait for the event that shows that no wait comes, for
    ///     example the end of a call.
    func waitForSleepers(atLeast count: Int, orUntil ended: @escaping @Sendable () async -> Void) async {
        await Waits.untilFirstEnds({ await self.waitForSleepers(atLeast: count) }, ended)
    }

    /// The last step of ``elapse(_:endingWait:)``: the move that must end the
    /// timer, and that the move before it must not reach.
    static let lastStepOfATimer = Duration.nanoseconds(1)

    /// Moves this clock to the end of the one timer that `waiting` waits on,
    /// and returns the result of `waiting`.
    ///
    /// The clock must hold no other wait. First the timer of `waiting` must
    /// wait on this clock. Then the clock moves to one step before `seconds`,
    /// and the timer must still wait. Then the clock moves the last step, and
    /// the timer must end. A task that sets no timer, or a timer that ends
    /// before or after `seconds`, makes the test fail, and the test does not
    /// hang.
    ///
    /// - Parameters:
    ///   - seconds: The length of the timer, in seconds.
    ///   - waiting: The task that waits on the timer.
    /// - Returns: The value of `waiting`.
    /// - Throws: When the timer did not wait on this clock, when it did not
    ///   end at `seconds`, or the error of `waiting`.
    func elapse<Value: Sendable, Failure: Error>(
        _ seconds: Double, endingWait waiting: Task<Value, Failure>
    ) async throws -> Value {
        try await elapseOneTimer(seconds, among: 1) { _ = await waiting.result }
        return try await waiting.result.get()
    }

    /// Moves this clock to the end of one timer of `seconds`, while `count`
    /// timers wait on it.
    ///
    /// First `count` timers must wait on this clock, or `ended` must end.
    /// Then the clock moves to one step before `seconds`, and each timer
    /// must still wait. Then the clock moves the last step, and exactly one
    /// timer must end. A wrong number of timers, or a timer that ends before
    /// or after `seconds`, makes the test fail, and the test does not hang.
    ///
    /// - Parameters:
    ///   - seconds: The length of the timer that must end, in seconds.
    ///   - count: The number of timers that wait before the move.
    ///   - ended: The wait for the event that shows that no more timers
    ///     come, for example the end of a call.
    /// - Throws: When the number of timers is wrong, or no single timer ended
    ///   at `seconds`.
    func elapseOneTimer(
        _ seconds: Double, among count: Int, orUntil ended: @escaping @Sendable () async -> Void
    ) async throws {
        await waitForSleepers(atLeast: count, orUntil: ended)
        try #require(sleeperCount == count, "\(sleeperCount) timers wait on the clock, not \(count)")
        advance(by: .seconds(seconds) - Self.lastStepOfATimer)
        try #require(sleeperCount == count, "a timer ended before \(seconds) seconds")
        advance(by: Self.lastStepOfATimer)
        try #require(sleeperCount == count - 1, "no timer ended at \(seconds) seconds")
    }
}

/// Keeps each terminal event that a run plane gives to its settlement
/// observer, so a test waits for the settle of a run with no poll.
final class SettledRunLog: BackgroundRunSettlementObserver {
    /// Each terminal event, in delivery order.
    let terminals = Recorder<OperationEvent>()

    /// Keeps `terminal`.
    ///
    /// - Parameter terminal: The terminal event of the run.
    func deliver(settledTerminal terminal: OperationEvent) async {
        terminals.append(terminal)
    }
}

/// A run plane whose timers wait on a ``ManualRunClock``, with a log of the
/// runs that settle on it by themselves.
///
/// A settle period on this plane ends only when the test moves the clock.
/// The run plane resumes each wait for a run before it gives the terminal
/// event to the log. Thus, when the log has the terminal event, each call
/// that waits for that run already has the settlement, and a move of the
/// clock cannot change its answer.
struct ManualSettlePlane {
    /// One call that waits on the plane for its run.
    struct Call<Value: Sendable> {
        /// The task of the call.
        let task: Task<Value, any Error>

        /// The number of runs that settled on the plane before the call
        /// started.
        let settledBefore: Int
    }

    /// The clock of the timers of the plane.
    let clock: ManualRunClock

    /// The run plane.
    let runPlane: RunPlane

    /// The log of the runs that settled by themselves.
    let settledRuns: SettledRunLog

    /// Makes a plane on a new manual clock, with a new log as its settlement
    /// observer. The plane keeps the log.
    ///
    /// - Returns: The plane.
    static func make() async -> ManualSettlePlane {
        let clock = ManualRunClock()
        let plane = ManualSettlePlane(clock: clock, runPlane: RunPlane(clock: clock), settledRuns: SettledRunLog())
        await plane.runPlane.attach(settlementObserver: plane.settledRuns)
        return plane
    }

    /// Starts `body`, a call that waits on this plane for its run.
    ///
    /// - Parameter body: The call.
    /// - Returns: The started call.
    func start<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) -> Call<Value> {
        // The count comes before the start, so no settle of this call is in it.
        let settledBefore = settledRuns.terminals.values.count
        return Call(task: Task { try await body() }, settledBefore: settledBefore)
    }

    /// The answer of `call`, a call that waits for its run up to `grace`.
    ///
    /// The wait ends when the call ends, or when a run settles on this plane
    /// first. Then the clock moves past `grace`. A call that did not see the
    /// settle then ends at its deadline with the pending envelope, and the
    /// test fails and does not hang. A run that never settles, in a call that
    /// never ends, gives no event to wait for.
    ///
    /// - Parameters:
    ///   - call: The started call.
    ///   - grace: The settle period of the call, in seconds.
    /// - Returns: The value of the call.
    /// - Throws: The error of the call.
    func answer<Value: Sendable>(of call: Call<Value>, settlingWithin grace: TimeInterval) async throws -> Value {
        let terminals = settledRuns.terminals
        let task = call.task
        await Waits.untilFirstEnds(
            { await terminals.waitUntil { $0.count > call.settledBefore } }, { _ = await task.result })
        clock.advance(by: .seconds(grace))
        return try await task.value
    }

    /// Starts `body`, a call that waits on this plane for its run up to
    /// `grace`, and returns its answer. See ``answer(of:settlingWithin:)``.
    ///
    /// - Parameters:
    ///   - grace: The settle period of the call, in seconds.
    ///   - body: The call.
    /// - Returns: The value of the call.
    /// - Throws: The error of the call.
    func answer<Value: Sendable>(
        settlingWithin grace: TimeInterval, of body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await answer(of: start(body), settlingWithin: grace)
    }
}

/// The end of each question that a test finds still open.
enum OpenQuestions {
    /// The answer that ends a question that a test finds still open.
    static let endedByTheTest = ElicitationResponse.cancel(reason: "the test ended a question that is still open")

    /// Ends the question `elicitationId` when it is still open on `runPlane`,
    /// and then records an issue.
    ///
    /// A run plane that did not give the answer to the asker leaves the
    /// question open. The end gives the asker an answer, thus a wait for the
    /// asker ends, and the test fails and does not hang.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - runPlane: The run plane.
    static func endIfOpen(_ elicitationId: ULID, on runPlane: RunPlane) async {
        let open = await runPlane.openElicitations().map(\.elicitationId)
        if open.contains(elicitationId) {
            Issue.record("the question \(elicitationId) is still open, so its answer did not reach the asker")
            _ = await runPlane.endElicitation(elicitationId, with: endedByTheTest)
        }
    }
}

/// The task of a test that asks one question and waits for its answer.
///
/// No wait of it hangs when the run plane is wrong.
/// ``waitUntilAsked(_:)`` also ends when the task ends. ``answer(on:)`` ends
/// the question when it is still open, and only then waits for the task.
struct QuestionTask<Value: Sendable> {
    /// The id of the question.
    let elicitationId: ULID

    /// The task that asks the question and gives the answer.
    let task: Task<Value, any Error>

    /// Starts `body`, which asks the question `elicitationId`.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question that `body` asks.
    ///   - body: The work that ends when the question gets its answer.
    init(asking elicitationId: ULID, running body: @escaping @Sendable () async throws -> Value) {
        self.elicitationId = elicitationId
        task = Task { try await body() }
    }

    /// Waits until `asked` ends, or until the task ends first.
    ///
    /// - Parameter asked: The wait for the event that tells that the question
    ///   is open, for example the post of its elicitation event.
    func waitUntilAsked(_ asked: @escaping @Sendable () async -> Void) async {
        let task = task
        await Waits.untilFirstEnds(asked, { _ = await task.result })
    }

    /// The answer that the task got.
    ///
    /// - Parameter runPlane: The run plane that holds the question.
    /// - Returns: The value of the task.
    /// - Throws: The error of the task.
    func answer(on runPlane: RunPlane) async throws -> Value {
        await OpenQuestions.endIfOpen(elicitationId, on: runPlane)
        return try await task.value
    }
}

extension QuestionTask where Value == ElicitationResponse {
    /// Asks `request` on `runPlane` for the run of `runToken`. Returns when
    /// the run plane posted the question, or when the asker got an answer
    /// first.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - runToken: The completion token of the run that asks.
    ///   - runPlane: The run plane.
    /// - Returns: The task that waits for the answer.
    static func ask(_ request: ElicitationRequest, runToken: String, on runPlane: RunPlane) async -> QuestionTask {
        let posted = RunLatch()
        let question = QuestionTask(asking: request.elicitationId) {
            await runPlane.awaitAnswer(to: request, runToken: runToken) { posted.open() }
        }
        await question.waitUntilAsked { await posted.waitUntilOpen() }
        return question
    }
}
