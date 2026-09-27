/// The kind of work of a background run. The kind tells what its canceler
/// can promise.
public enum RunKind: String, Codable, Sendable, Equatable {
    /// An in-process Swift `Task`. A cancel is only a request, so a canceler
    /// reports ``OperationOutcome/cancelled``.
    case swiftTask

    /// An OS process group that a shell capability owns. That capability
    /// kills the group with `killpg(SIGKILL)`, so its canceler reports
    /// ``OperationOutcome/stopped``.
    case process
}

/// One running background run. It has the identity and the latest progress,
/// never the output.
public struct BackgroundRun: Sendable, Equatable {
    /// The completion token of the run. It is also the `correlationID` of
    /// each event of the run.
    public let completionToken: String

    /// The name of the tool that owns the run.
    public let tool: String

    /// The `"verb noun"` op string of the run.
    public let op: String

    /// The kind of work of the run.
    public let kind: RunKind

    /// The latest progress detail, or `nil` before the first progress event.
    public let latestProgressDetail: String?
}

/// The result of a wait for a background run.
public enum WaitOutcome: Sendable, Equatable {
    /// The run settled. The terminal event has the report of the tool as its
    /// `detail`, and its outcome.
    case settled(OperationEvent)

    /// The deadline came before the run settled. The run continues.
    case deadlineElapsed

    /// The waiting task was cancelled before the run settled. The run
    /// continues.
    case cancelled

    /// No run has this token. Nothing occurs.
    case unknownToken
}

/// The result of a cancel of a background run.
public enum CancelOutcome: Sendable, Equatable {
    /// The canceler ran. This is the outcome that it reported.
    case reported(OperationOutcome)

    /// The run settled before the cancel. The terminal event tells how it
    /// ended.
    case alreadySettled(OperationEvent)

    /// No run has this token. Nothing occurs.
    case unknownToken
}
