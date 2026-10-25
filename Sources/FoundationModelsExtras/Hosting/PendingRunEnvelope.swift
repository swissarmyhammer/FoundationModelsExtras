import Foundation
import ULID

/// The text that a background call returns in place of its result, when the
/// run continues past its ``BackgroundTool/inlineSettleGrace``.
///
/// `pending` is always `true`, and ``next`` tells the model what to do while
/// the run continues. By default, the session injects the result into the
/// conversation when the run finishes, and the model calls no tool to wait.
/// A run that ended inside its grace answers with its own result and never
/// with an envelope. ``rendered`` is the wire form.
public struct PendingRunEnvelope: Codable, Sendable, Equatable {
    /// Always `true`: the result is not in this envelope.
    public let pending: Bool

    /// The completion token of the run: a ULID string. It is also the
    /// `correlationID` of each event of the run.
    public let completionToken: String

    /// What the model must do in place of an answer, as plain text.
    public let next: String

    /// Makes the envelope of a run that continues.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - next: The collect sentence, or `nil` for
    ///     ``defaultCollectInstruction(forCompletionToken:describing:)``
    ///     with no description.
    init(completionToken: String, next: String? = nil) {
        self.pending = true
        self.completionToken = completionToken
        self.next = next ?? Self.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// What the model must do while work continues in the background, as
    /// plain text. It names no call: it follows a text that names the work.
    ///
    /// The model works without turns. A result and mail come in as messages,
    /// and text that the model writes is a status message to whoever started
    /// it. So the text tells the model that the result arrives as a message,
    /// that no tool makes it come sooner, and that with no other work left it
    /// posts its status. It never asks for an empty output, which the model
    /// cannot give. This package owns this text and
    /// ``waitingStatusInstruction(for:)``. Other packages that tell the model
    /// about pending work use them.
    public static let pendingWorkInstruction: String =
        singleResultInstruction
        + " If none is left, post your status as plain text: what you wait on and its completion token."

    /// The default description of a call that has only its token.
    static let fallbackCallDescription = "this call"

    /// What the model must do while one call runs: the result arrives as a
    /// message, and other work goes on.
    private static let singleResultInstruction =
        "Its result will arrive in this conversation as a message when it is ready. You do not need "
        + "to wait for it or check on it, and no tool can make it come sooner. Go on with any work "
        + "that does not need it."

    /// What the model must do while several calls run.
    private static let severalResultsInstruction =
        "Their results will arrive in this conversation as messages when they are ready. You do not "
        + "need to wait for them or check on them, and no tool can make them come sooner. Go on with "
        + "any work that does not need them."

    /// What the model must do while `calls` run in the background, as plain
    /// text: each call by its description and completion token, what to do
    /// meanwhile, and the status line to post when no other work is left,
    /// `Waiting on <description> (<token>).`
    ///
    /// A pending envelope gives this text for its one call. A tool that
    /// answers a call that does nothing, while calls are open, gives it for
    /// each open call.
    ///
    /// - Parameter calls: The open calls, in order: a short description of
    ///   each, such as `execute python tests/runtests.py`, and its completion
    ///   token.
    /// - Returns: The text. With no call, it says that nothing runs and asks
    ///   for a status.
    public static func waitingStatusInstruction(for calls: [(description: String, completionToken: String)]) -> String {
        guard !calls.isEmpty else {
            return "Nothing is running in the background. If no work is left, post your status as plain text."
        }
        let named = calls.map { "\($0.description) (completion token \"\($0.completionToken)\")" }
        let status = calls.map { "\($0.description) (\($0.completionToken))" }
        let instruction = calls.count == 1 ? singleResultInstruction : severalResultsInstruction
        return "Running in the background: \(named.joined(separator: "; ")). \(instruction) "
            + "If none is left, post your status as plain text: `Waiting on \(status.joined(separator: "; ")).`"
    }

    /// The default `next` text of a pending envelope:
    /// ``waitingStatusInstruction(for:)`` of its one call.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - description: A short description of the call, such as
    ///     `agent coder`, or `nil` to name it "this call".
    /// - Returns: The text for the call.
    public static func defaultCollectInstruction(
        forCompletionToken completionToken: String, describing description: String? = nil
    ) -> String {
        waitingStatusInstruction(
            for: [(description: description ?? fallbackCallDescription, completionToken: completionToken)])
    }

    /// The envelope as JSON, with the fields always in this order:
    /// `pending`, `completionToken`, `next`.
    ///
    /// ``makeDecoded(fromRendered:)`` compares a text with this value, so this
    /// property sets the only form that is recognized.
    public var rendered: String {
        let fields = [
            "\"pending\":\(pending)",
            "\"completionToken\":" + Self.jsonString(completionToken),
            "\"next\":" + Self.jsonString(next),
        ]
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Tells if `text` is a rendered envelope. A decorator uses this to tell
    /// an envelope from ordinary tool output.
    ///
    /// - Parameter text: The tool output.
    /// - Returns: `true` when `text` is a rendered envelope.
    public static func isRendered(text: String) -> Bool {
        makeDecoded(fromRendered: text) != nil
    }

    /// The envelope that `text` renders, or `nil` when `text` is not one.
    ///
    /// The match is exact: `text` must decode, be pending, hold a valid ULID
    /// token, and be equal to the ``rendered`` form of what it decodes to.
    ///
    /// - Parameter text: The tool output.
    /// - Returns: The decoded envelope, or `nil`.
    public static func makeDecoded(fromRendered text: String) -> PendingRunEnvelope? {
        guard
            let envelope = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
            envelope.pending,
            ULID(ulidString: envelope.completionToken) != nil,
            text == envelope.rendered
        else {
            return nil
        }
        return envelope
    }

    /// The first Unicode scalar value that JSON does not escape.
    private static let firstUnescapedScalarValue: UInt32 = 0x20

    /// `text` as a JSON string literal, with its quotes.
    ///
    /// - Parameter text: The plain text.
    /// - Returns: The quoted and escaped text.
    private static func jsonString(_ text: String) -> String {
        var body = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": body += "\\\""
            case "\\": body += "\\\\"
            case "\n": body += "\\n"
            case "\r": body += "\\r"
            case "\t": body += "\\t"
            case _ where scalar.value < firstUnescapedScalarValue:
                body += String(format: "\\u%04x", scalar.value)
            default:
                body.unicodeScalars.append(scalar)
            }
        }
        return body + "\""
    }
}
