/// The point in the history of a source session where a fork cuts it. The
/// fork gets a copy of the history up to this point.
///
/// ## Turns
///
/// ``afterTurn(_:)`` and ``beforeTurn(_:)`` count turns in the recorded
/// history of the source. A turn is one `prompt` entry and all the entries
/// after it, up to the next `prompt` entry. A `prompt` entry is a user
/// message, or a delivered message that starts an answer: a message from
/// another session, or a delivered inbox message. The index is 0-based:
/// turn 0 is the first prompt after the instructions.
///
/// The index counts each `prompt` entry that the history of the source ever
/// recorded, also the turns that a compaction folded. Thus the index agrees
/// with the transcript of the client. A cut after the last compaction gives
/// the summary of the compaction and the turns after it, up to the cut. A cut
/// in the folded turns is out of range, because the summary also covers
/// turns after the cut.
///
/// An index that does not exist is out of range. ``afterTurn(_:)`` of a turn
/// that still runs is out of range too.
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

    /// The history up to the end of the turn with this index. The turn must
    /// be complete.
    case afterTurn(Int)

    /// The history up to the `prompt` entry of the turn with this index, but
    /// not that entry.
    case beforeTurn(Int)
}
