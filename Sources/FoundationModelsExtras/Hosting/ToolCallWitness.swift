import FoundationModels
import ULID

/// Gets the start of each inner call that ``ToolContext/mount(_:op:as:)``
/// mounted on a site with this witness.
///
/// A run that makes its own inner calls, for example a script runner, calls
/// its tools through ``ToolContext/mount(_:op:as:)``. The decorator of the
/// session sees only the outer, model-facing call, so a host that must know
/// each inner call gives a witness to the ``MountSite`` of the session.
///
/// The witness never sees an outer call: the site that a host gives to
/// ``ToolMounting/makeWrapped(tool:site:configuration:)`` does not report its
/// own calls. Thus a host that also decorates each outer call counts each
/// call one time. The site of a child session drops the witness, see
/// ``MountSite/childSite(sessionID:runPlane:sink:)``.
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

    /// Makes the record of one call.
    ///
    /// - Parameters:
    ///   - tool: The name of the called tool.
    ///   - op: The op of the mount, or the tool name when the mount gives
    ///     none.
    ///   - arguments: The arguments of the call, or `nil`.
    ///   - sessionID: The session of the site that runs the call.
    public init(tool: String, op: String, arguments: GeneratedContent?, sessionID: ULID) {
        self.tool = tool
        self.op = op
        self.arguments = arguments
        self.sessionID = sessionID
    }
}
