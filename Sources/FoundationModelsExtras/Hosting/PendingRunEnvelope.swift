import Foundation
import ULID

/// The text that a background call returns in place of its result, when the
/// run continues past its ``BackgroundTool/inlineSettleGrace``.
///
/// `pending` is always `true`, and ``next`` tells the model how to collect
/// the result later. A run that ended inside its grace answers with its own
/// result and never with an envelope. ``rendered`` is the wire form.
public struct PendingRunEnvelope: Codable, Sendable, Equatable {
    /// Always `true`: the model must collect the result later.
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

    /// The default `next` text of a pending envelope.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The sentence for `completionToken`.
    public static func defaultCollectInstruction(forCompletionToken completionToken: String) -> String {
        "This run continues in the background. Do not answer yet, and never invent or guess its result. "
            + "The session reports the result when the run settles. "
            + "To collect it earlier, call the wait tool with completionToken \"\(completionToken)\"; "
            + "if the run is not finished yet, call wait again with the same completionToken."
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
