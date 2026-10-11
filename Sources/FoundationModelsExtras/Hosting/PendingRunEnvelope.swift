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
    ///     ``defaultCollectInstruction(forCompletionToken:)``.
    init(completionToken: String, next: String? = nil) {
        self.pending = true
        self.completionToken = completionToken
        self.next = next ?? Self.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// What the model must do while work continues in the background, as
    /// plain text.
    ///
    /// The session injects the result into the conversation as a new message
    /// when the work finishes. Thus the text tells the model not to call a
    /// tool to wait or to check, and to do nothing when no other work can be
    /// done. This package owns the one copy of this text. Other packages that
    /// tell the model about pending work use this property.
    public static let pendingWorkInstruction: String =
        "This is not the result. When the work finishes, the session injects its result into this "
        + "conversation as a new message. That message starts you working again, so you do not need to "
        + "wait, to check, or to ask for it. Do not call a tool to wait or to check. If you have other "
        + "work that does not need this result, do that work now. If no other work can be done until "
        + "the result comes back, do nothing: write no text and call no tool. When the injected result "
        + "arrives, continue the task from it."

    /// The default `next` text of a pending envelope: one sentence that names
    /// the run by its completion token, one space, then
    /// ``pendingWorkInstruction``.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The text for `completionToken`.
    public static func defaultCollectInstruction(forCompletionToken completionToken: String) -> String {
        "This run continues in the background, with completion token \"\(completionToken)\". "
            + pendingWorkInstruction
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
