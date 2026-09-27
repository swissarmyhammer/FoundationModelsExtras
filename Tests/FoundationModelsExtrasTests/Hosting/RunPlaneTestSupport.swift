@testable import FoundationModelsExtras
import Foundation
import Testing

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
                return OperationEvent(
                    tool: tool,
                    op: op,
                    correlationID: token,
                    kind: .completed,
                    detail: detailOnSettle,
                    outcome: cancelRequests.values.isEmpty ? .succeeded : .cancelled
                )
            }
        )
        return token
    }
}

/// Thrown by ``AnswerDrivenRun/deliveredAnswer()`` when no answer reached the
/// run inside the bound.
struct AnswerNeverDelivered: Error {}

/// Records that an ``AnswerDrivenRun`` ended, so a test can ask without a wait.
private actor RunCompletion {
    /// Whether the run ended.
    private(set) var isFinished = false

    /// Records that the run ended.
    func finish() {
        isFinished = true
    }
}

/// Work that ends only when an answer reaches it, for example a suspended
/// elicitation. The test reads the result with a bound, so a broken answer
/// route fails one test and does not stop the whole test run.
///
/// The bound does not await the run when no answer came: a run that waits for
/// an answer ignores cancellation, so a wait for it can never end.
struct AnswerDrivenRun<Value: Sendable> {
    /// What the run waits for, named in the issue when no answer comes.
    private let label: String

    /// Tells if the run ended.
    private let completion: RunCompletion

    /// The run.
    private let task: Task<Value, any Error>

    /// Starts `body`.
    ///
    /// - Parameters:
    ///   - label: What the run waits for.
    ///   - body: The work that ends when an answer reaches it.
    init(waitingFor label: String, running body: @escaping @Sendable () async throws -> Value) {
        let completion = RunCompletion()
        self.label = label
        self.completion = completion
        self.task = Task {
            do {
                let value = try await body()
                await completion.finish()
                return value
            } catch {
                await completion.finish()
                throw error
            }
        }
    }

    /// The value of the run, when an answer reached it before the bound of
    /// ``BoundedWait``.
    ///
    /// - Returns: The value of the run.
    /// - Throws: ``AnswerNeverDelivered`` when no answer came, or the error of
    ///   the run.
    func deliveredAnswer() async throws -> Value {
        let completion = completion
        guard await BoundedWait.conditionReached("an answer to \(label)", when: { await completion.isFinished }) else {
            task.cancel()
            throw AnswerNeverDelivered()
        }
        return try await task.value
    }

    /// The value of the run, with no wall clock. A test that calls this sets
    /// a `.timeLimit`, which ends the wait when no answer comes.
    ///
    /// - Returns: The value of the run.
    /// - Throws: `CancellationError` when the time limit ended the wait, or
    ///   the error of the run.
    func answerOnceDelivered() async throws -> Value {
        let completion = completion
        do {
            try await AwaitedCondition.wait { await completion.isFinished }
        } catch {
            task.cancel()
            throw error
        }
        return try await task.value
    }
}

/// A wait for a state that no event names, with no wall clock. A loaded
/// machine makes the wait longer, never wrong. The `.timeLimit` of the test
/// ends a wait for a state that never comes.
enum AwaitedCondition {
    /// The pause between two reads of the condition.
    private static let pollIntervalNanoseconds: UInt64 = 5_000_000

    /// Reads `condition` until it is true.
    ///
    /// - Parameter condition: The state to wait for.
    /// - Throws: `CancellationError` when the test was cancelled first.
    static func wait(until condition: @Sendable () async -> Bool) async throws {
        while await !condition() {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
