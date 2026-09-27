import Foundation
import ULID

/// The text that a background call returns in place of its result.
///
/// When the run continues, `pending` is `true` and ``next`` tells the model
/// how to collect the result later. When the run ended inside the
/// ``BackgroundTool/inlineSettleGrace`` of the tool, `pending` is `false`,
/// and the envelope also holds ``outcome`` and ``detail``. ``rendered`` is
/// the wire form.
public struct PendingRunEnvelope: Codable, Sendable, Equatable {
    /// `true` when the model must collect the result later, `false` when
    /// ``detail`` holds the result.
    public let pending: Bool

    /// The completion token of the run: a ULID string. It is also the
    /// `correlationID` of each event of the run.
    public let completionToken: String

    /// The outcome of the run as its wire word, or `nil` while the run
    /// continues.
    public let outcome: String?

    /// The report of the run, or `nil` while the run continues.
    public let detail: String?

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
        self.outcome = nil
        self.detail = nil
        self.next = next ?? Self.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// Makes the envelope of a run that ended before the call answered.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - outcome: The outcome of the run, as its wire word.
    ///   - detail: The report of the run.
    ///   - next: The sentence that tells the model to answer from `detail`.
    init(completionToken: String, outcome: String, detail: String, next: String) {
        self.pending = false
        self.completionToken = completionToken
        self.outcome = outcome
        self.detail = detail
        self.next = next
    }

    /// This envelope with `detail` in place of its detail. A layer that cuts
    /// a long result uses it, and the control fields stay the same.
    ///
    /// - Parameter detail: The new report of the run.
    /// - Returns: The changed envelope, or this envelope when it is pending.
    public func replacing(detail: String) -> PendingRunEnvelope {
        guard let outcome else { return self }
        return PendingRunEnvelope(completionToken: completionToken, outcome: outcome, detail: detail, next: next)
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

    /// The default `next` text of a settled envelope.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The sentence for `completionToken`.
    public static func defaultResultInstruction(forCompletionToken completionToken: String) -> String {
        "This run is finished and its result is the detail field above. Answer from that result now. "
            + "Do not call the wait tool for completionToken \"\(completionToken)\", "
            + "and never reply that the result will arrive later."
    }

    /// The envelope as JSON, with the fields always in this order:
    /// `pending`, `completionToken`, `outcome`, `detail`, `next`.
    ///
    /// ``makeDecoded(fromRendered:)`` compares a text with this value, so this
    /// property sets the only form that is recognized.
    public var rendered: String {
        var fields = [
            "\"pending\":\(pending)",
            "\"completionToken\":" + Self.jsonString(completionToken),
        ]
        if let outcome {
            fields.append("\"outcome\":" + Self.jsonString(outcome))
        }
        if let detail {
            fields.append("\"detail\":" + Self.jsonString(detail))
        }
        fields.append("\"next\":" + Self.jsonString(next))
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
    /// The match is exact: `text` must decode, hold a valid ULID token, have
    /// both result fields when settled and neither when pending, and be
    /// equal to the ``rendered`` form of what it decodes to.
    ///
    /// - Parameter text: The tool output.
    /// - Returns: The decoded envelope, or `nil`.
    public static func makeDecoded(fromRendered text: String) -> PendingRunEnvelope? {
        guard
            let envelope = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
            ULID(ulidString: envelope.completionToken) != nil,
            envelope.pending == (envelope.detail == nil),
            envelope.pending == (envelope.outcome == nil),
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
