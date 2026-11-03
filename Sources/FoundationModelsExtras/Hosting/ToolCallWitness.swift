import FoundationModels
import ULID

/// Gets the start of each inner call that ``ToolContext/mount(_:op:as:)``
/// mounted on a site with this witness, and the end of each call, inner or
/// outer, with its final result.
///
/// A run that makes its own inner calls, for example a script runner, calls
/// its tools through ``ToolContext/mount(_:op:as:)``. The decorator of the
/// session sees only the outer, model-facing call, so a host that must know
/// each inner call gives a witness to the ``MountSite`` of the session.
///
/// The witness never sees the start of an outer call: the site that a host
/// gives to ``ToolMounting/makeWrapped(tool:site:configuration:)`` does not
/// report the start of its own calls. Thus a host that also decorates each
/// outer call counts each start one time. It does get the end of an outer
/// call, with the final result: a host that must read how each model-facing
/// call ended gives a witness to its site. The site of a child session drops
/// the witness, see ``MountSite/childSite(sessionID:runPlane:sink:)``.
public protocol ToolCallWitness: Sendable {
    /// Called once at the start of each inner call that
    /// ``ToolContext/mount(_:op:as:)`` mounted on a site with this witness,
    /// before the call runs.
    ///
    /// The call waits for this method, so it must return at once and must not
    /// block. The witness never changes, delays or fails the call.
    ///
    /// - Parameter call: The call that begins.
    func toolCallWillBegin(_ call: WitnessedToolCall)

    /// Called once at the end of each call on a site with this witness, inner
    /// or outer, after the body returned and the terminal event, the close
    /// record and the report of the call went out.
    ///
    /// The result is the final one: ``OperationOutcome/failed`` with the value
    /// of ``ToolContext/reportFailure(value:)`` when the tool reported a
    /// failure, the outcome of a stop, a timeout or a cancel when one ended
    /// the run, and ``OperationOutcome/succeeded`` for an output with no
    /// report. A background call ends when its run settles, not when the
    /// call returns its pending envelope.
    ///
    /// The call waits for this method, so it must return at once and must not
    /// block. The witness never changes, delays or fails the call. The default
    /// does nothing.
    ///
    /// - Parameters:
    ///   - call: The call that ended.
    ///   - result: How the call ended, and its value.
    func toolCallDidEnd(_ call: WitnessedToolCall, result: OperationResult)
}

extension ToolCallWitness {
    /// Does nothing: a witness that only needs the start of a call keeps this
    /// default.
    public func toolCallDidEnd(_ call: WitnessedToolCall, result: OperationResult) {}
}

/// One inner call that a ``ToolCallWitness`` sees at its start.
public struct WitnessedToolCall: Sendable {
    /// The name of the called tool.
    public let tool: String

    /// The `"verb noun"` op of the mount, or the tool name when the mount
    /// gives none.
    public let op: String

    /// The arguments of the call, or `nil` when the arguments are not
    /// `ConvertibleToGeneratedContent`.
    public let arguments: GeneratedContent?

    /// The session of the site that runs the call.
    public let sessionID: ULID

    /// The completion token of the run of the call, or `nil` where the call
    /// has none. The start and the end of one call give the same value, so a
    /// host matches a start to its end with it.
    public let correlationID: String?

    /// Makes the record of one call.
    ///
    /// - Parameters:
    ///   - tool: The name of the called tool.
    ///   - op: The op of the mount, or the tool name when the mount gives
    ///     none.
    ///   - arguments: The arguments of the call, or `nil`.
    ///   - sessionID: The session of the site that runs the call.
    ///   - correlationID: The completion token of the run of the call, or
    ///     `nil` for none. The default is `nil`.
    public init(
        tool: String, op: String, arguments: GeneratedContent?, sessionID: ULID, correlationID: String? = nil
    ) {
        self.tool = tool
        self.op = op
        self.arguments = arguments
        self.sessionID = sessionID
        self.correlationID = correlationID
    }
}
