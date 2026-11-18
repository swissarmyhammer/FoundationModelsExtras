/// The point in the history of a source session where a fork cuts it. The
/// fork gets a copy of the history up to this point.
public enum SessionForkCut: Sendable, Codable, Equatable {
    /// The history up to the end of the last completed turn. The fork does
    /// not get a turn that runs.
    case lastCompletedTurn

    /// The source forks itself from a tool call. The fork gets the history up
    /// to that call, but not the call.
    case callingToolCall

    /// A position in the history of the source, as the directory counts it.
    /// The ACP agent maps an ACP message id to it.
    case historyPosition(Int)
}
