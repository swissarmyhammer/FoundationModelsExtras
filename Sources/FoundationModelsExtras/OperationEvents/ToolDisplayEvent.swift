/// One part of the display output of a tool: text, a diff, or JSON. The
/// shape agrees with the content of an ACP tool call
/// (https://agentclientprotocol.com/protocol/v2/tool-calls).
public enum ToolDisplayContent: Sendable, Equatable {
    /// Plain text for the client to show.
    case text(String)

    /// A change to one file.
    ///
    /// - Parameters:
    ///   - path: The path of the file.
    ///   - oldText: The text before the change, or `nil` for a new file.
    ///   - newText: The text after the change.
    case diff(path: String, oldText: String?, newText: String)

    /// A JSON text in a shape that the tool owns. This package does not read
    /// it.
    case json(String)
}

/// A display-only event of a tool: output or metadata for the client of the
/// host, and never for the model.
///
/// A tool posts it with ``ToolContext/post(display:)``, or with the helpers
/// ``ToolContext/emit(chunk:)`` and ``ToolContext/update(title:kind:locations:)``.
/// A sink gets it in ``OperationEventSink/post(display:)``. A display event
/// is a lane of its own, apart from ``OperationEvent``:
///
/// - It never goes into the model input. It is not an ``OperationEvent``, so
///   it never changes the progress detail of a run on the run plane.
/// - A sink never combines two display events. Each event goes to the client
///   in post order.
/// - A host never records it in the journal of the session. For this reason
///   the type is not `Codable`.
/// - It counts as a sign of life for the timeout of the run, the same as
///   progress. A tool that sends output to the client is alive.
/// - A background run that answers in its settle period does not withdraw
///   it. The model never reads it, and the client already shows it. See
///   ``StagedEventWithdrawing``.
///
/// A nested call that ``ToolContext/mount(_:op:as:)`` mounts sends each
/// display event again under the stamps of the mounting run, the same as
/// each other event of that call.
public struct ToolDisplayEvent: Sendable, Equatable {
    /// What a display event tells the client.
    public enum Kind: Sendable, Equatable {
        /// One more part of the output of the tool. The client adds it after
        /// the earlier parts.
        case contentChunk(ToolDisplayContent)

        /// The full output of the tool, in order. The client replaces the
        /// earlier parts with it.
        case contentReplace([ToolDisplayContent])

        /// New metadata of the tool call. A `nil` field does not change the
        /// value that the client has.
        ///
        /// - Parameters:
        ///   - title: The human-readable title of the call.
        ///   - kind: The category of the call.
        ///   - locations: The files that the call reads or changes.
        ///   - rawInput: The input of the call, as a JSON text.
        case metadata(title: String?, kind: ToolKind?, locations: [Location]?, rawInput: String?)
    }

    /// The category of a tool call. The client can use it to choose an icon.
    /// The wire values agree with ACP.
    public enum ToolKind: String, Sendable, Equatable {
        /// The call reads files or data.
        case read

        /// The call changes files or content.
        case edit

        /// The call removes files or data.
        case delete

        /// The call moves or renames files.
        case move

        /// The call searches for information.
        case search

        /// The call runs a command or code.
        case execute

        /// The call is internal reasoning or planning.
        case think

        /// The call gets external data.
        case fetch

        /// The call changes the session mode. Carried on the wire as
        /// `switch_mode`.
        case switchMode = "switch_mode"

        /// Another category.
        case other
    }

    /// A file that a tool call reads or changes, so that the client can
    /// follow it.
    public struct Location: Sendable, Equatable {
        /// The path of the file.
        public let path: String

        /// The line in the file, or `nil` for the full file.
        public let line: Int?

        /// Creates a location from its fields.
        ///
        /// - Parameters:
        ///   - path: The path of the file.
        ///   - line: The line in the file, or `nil` for the full file.
        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    /// The name of the tool that posted this event.
    public let tool: String

    /// The `"verb noun"` op string of the operation that posted this event.
    public let op: String

    /// The completion token of the run that posted this event. It is the
    /// `correlationID` of each ``OperationEvent`` of the same run.
    public let correlationID: String

    /// What this event tells the client.
    public let kind: Kind

    /// Creates an event from its fields.
    ///
    /// - Parameters:
    ///   - tool: The name of the posting tool.
    ///   - op: The `"verb noun"` op string of the posting operation.
    ///   - correlationID: The completion token of the run.
    ///   - kind: What the event tells the client.
    public init(tool: String, op: String, correlationID: String, kind: Kind) {
        self.tool = tool
        self.op = op
        self.correlationID = correlationID
        self.kind = kind
    }
}
