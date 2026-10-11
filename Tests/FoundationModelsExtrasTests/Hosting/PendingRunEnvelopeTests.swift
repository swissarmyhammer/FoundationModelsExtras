@testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the ``PendingRunEnvelope`` wire form: rendering, recognition,
/// and the default `next` sentences.
@Suite("PendingRunEnvelope: the background handle's wire form")
struct PendingRunEnvelopeTests {
    /// How many new tokens the round-trip test renders and recognizes.
    private static let wireFormTokenSampleCount = 32

    /// The fields of a rendered envelope, decoded apart from the type under
    /// test.
    private struct DecodedEnvelope: Decodable {
        let pending: Bool
        let completionToken: String
        let next: String
    }

    /// Decodes a rendered envelope with a plain JSON decoder.
    private static func decodeEnvelope(_ rendered: String) throws -> DecodedEnvelope {
        try JSONDecoder().decode(DecodedEnvelope.self, from: Data(rendered.utf8))
    }

    /// A collect sentence that a tool gives in place of the default.
    private static func toolCollectInstruction(forCompletionToken completionToken: String) -> String {
        "Call the fetch tool with ticket \"\(completionToken)\" to read the result."
    }

    /// Asserts that `text` contains every element of `facts`, each after the
    /// previous one.
    private static func expect(_ text: String, saysInOrder facts: [String]) {
        var searchStart = text.startIndex
        for fact in facts {
            guard let found = text.range(of: fact, range: searchStart..<text.endIndex) else {
                Issue.record("\"\(fact)\" is missing, or out of order, in: \(text)")
                return
            }
            searchStart = found.upperBound
        }
    }

    @Test("every freshly generated token renders to a recognized envelope that decodes back to itself")
    func renderedEnvelopeRoundTripsForFreshTokens() throws {
        for _ in 0..<Self.wireFormTokenSampleCount {
            let completionToken = ULID().ulidString
            let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

            #expect(PendingRunEnvelope.isRendered(text: rendered))
            let decoded = try Self.decodeEnvelope(rendered)
            #expect(decoded.pending)
            #expect(decoded.completionToken == completionToken)
        }
    }

    /// The text shapes the default sentence must not carry: a `runCode`
    /// snippet, the snippet-level `wait` call, any call syntax, the
    /// run-plane state names no host reports on the wire, and the old
    /// wait-tool text that made the model loop.
    private static let forbiddenDefaultCollectInstructionFragments = [
        "runCode",
        "return await wait",
        "wait(",
        "snippet",
        "settled",
        "deadline_elapsed",
        "wait tool",
        "call wait",
        "Do not answer yet",
    ]

    /// The pending-work text that the user approved, word for word.
    private static let approvedPendingWorkInstruction =
        "This is not the result. When the work finishes, the session injects its result into this "
        + "conversation as a new message. That message starts you working again, so you do not need to "
        + "wait, to check, or to ask for it. Do not call a tool to wait or to check. If you have other "
        + "work that does not need this result, do that work now. If no other work can be done until "
        + "the result comes back, do nothing: write no text and call no tool. When the injected result "
        + "arrives, continue the task from it."

    @Test("pendingWorkInstruction is the approved text, word for word")
    func pendingWorkInstructionIsTheApprovedText() {
        #expect(PendingRunEnvelope.pendingWorkInstruction == Self.approvedPendingWorkInstruction)
    }

    @Test("the default next sentence is the token sentence, one space, then pendingWorkInstruction")
    func defaultCollectInstructionIsTheTokenSentenceThenThePendingWorkInstruction() {
        let completionToken = ULID().ulidString

        #expect(
            PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
                == "This run continues in the background, with completion token \"\(completionToken)\". "
                + PendingRunEnvelope.pendingWorkInstruction
        )
    }

    @Test("the default next sentence says: the run continues in the background with its token, this is not the result, the session injects the result, call no tool to wait, and do nothing when no other work remains")
    func defaultCollectInstructionTellsTheModelNotToWait() throws {
        let completionToken = ULID().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let next = try Self.decodeEnvelope(rendered).next
        #expect(
            next == PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
        )
        Self.expect(
            next,
            saysInOrder: [
                // The run goes on behind the answer, under its real token.
                "continues in the background",
                completionToken,
                // The envelope is not the result.
                "not the result",
                // The session injects the result as a new message.
                "injects its result",
                // No tool call to wait or to check.
                "Do not call a tool to wait or to check",
                // With no other work, the model does nothing.
                "do nothing",
            ]
        )
        for fragment in Self.forbiddenDefaultCollectInstructionFragments {
            #expect(!next.contains(fragment), "default sentence must not say \(fragment)")
        }
    }

    @Test("an envelope is recognized whatever collect sentence it carries: the default, a tool's own, and one that needs JSON escaping")
    func renderedEnvelopeIsRecognizedWithAnyCollectInstruction() throws {
        let completionToken = ULID().ulidString
        let sentences = [
            PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken),
            Self.toolCollectInstruction(forCompletionToken: completionToken),
            // Quotes, a backslash, a newline, and a tab all need escaping
            // inside the JSON string the `next` field is.
            "Say \"\(completionToken)\" \\ twice\n\tthen stop.",
        ]

        for next in sentences {
            let rendered = PendingRunEnvelope(completionToken: completionToken, next: next).rendered

            #expect(PendingRunEnvelope.isRendered(text: rendered))
            let decoded = try Self.decodeEnvelope(rendered)
            #expect(decoded.completionToken == completionToken)
            #expect(decoded.next == next)
        }
    }

    @Test("the rendered envelope holds only the pending flag, the completion token and the next sentence, in that order")
    func renderedEnvelopeHoldsOnlyThePendingFields() {
        let completionToken = ULID().ulidString
        let envelope = PendingRunEnvelope(completionToken: completionToken, next: "collect")

        #expect(envelope.pending)
        #expect(envelope.rendered == "{\"pending\":true,\"completionToken\":\"\(completionToken)\",\"next\":\"collect\"}")
    }

    @Test("makeDecoded rejects a text whose pending flag is false, also when its frame is otherwise exact")
    func makeDecodedRejectsANotPendingText() {
        let completionToken = ULID().ulidString
        let pendingText = "{\"pending\":true,\"completionToken\":\"\(completionToken)\",\"next\":\"answer\"}"
        let notPending = [
            // The exact frame of a pending envelope, with the flag false.
            "{\"pending\":false,\"completionToken\":\"\(completionToken)\",\"next\":\"answer\"}",
            // The old settled frame, with a result.
            "{\"pending\":false,\"completionToken\":\"\(completionToken)\",\"outcome\":\"succeeded\","
                + "\"detail\":\"done\",\"next\":\"answer\"}",
        ]

        #expect(PendingRunEnvelope.makeDecoded(fromRendered: pendingText) != nil)
        for text in notPending {
            #expect(PendingRunEnvelope.makeDecoded(fromRendered: text) == nil)
            #expect(!PendingRunEnvelope.isRendered(text: text))
        }
    }

    @Test("a pending envelope that also carries result fields is not recognized")
    func pendingEnvelopeWithResultFieldsIsRejected() {
        let completionToken = ULID().ulidString

        let text =
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\",\"outcome\":\"succeeded\","
            + "\"detail\":\"done\",\"next\":\"answer\"}"

        #expect(PendingRunEnvelope.makeDecoded(fromRendered: text) == nil)
        #expect(!PendingRunEnvelope.isRendered(text: text))
    }

    @Test("an envelope with anything added to or removed from it is not recognized")
    func alteredLengthIsRejected() {
        let completionToken = ULID().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let tampered = [
            rendered + " ",
            " " + rendered,
            String(rendered.dropLast()),
            String(rendered.dropFirst()),
            // Both slots shortened to a 25-character stub.
            rendered.replacingOccurrences(
                of: completionToken, with: String(completionToken.dropLast())
            ),
        ]

        for text in tampered {
            #expect(!PendingRunEnvelope.isRendered(text: text))
        }
    }

    @Test("an envelope whose twin slots hold a same-length non-ULID is not recognized")
    func nonULIDTokenSlotsAreRejected() {
        let completionToken = ULID().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let notAToken = String(repeating: "!", count: completionToken.count)
        let tampered = rendered.replacingOccurrences(of: completionToken, with: notAToken)

        #expect(tampered.count == rendered.count)
        #expect(!PendingRunEnvelope.isRendered(text: tampered))
    }

    @Test("neither ordinary tool output nor an envelope missing its next instruction is recognized")
    func nonEnvelopeOutputIsRejected() {
        let completionToken = ULID().ulidString

        let notEnvelopes = [
            "",
            "fast: x",
            "{}",
            // A frame with no `next` field.
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\"}",
            // The same facts as JSON, but not this envelope's byte shape.
            "{\"completionToken\":\"\(completionToken)\",\"pending\":true,\"next\":\"wait\"}",
            // The frame, but a `next` field that is not a JSON string.
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\",\"next\":\"a\"b\"}",
            // The frame, but the `next` field is not closed.
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\",\"next\":\"open}",
        ]

        for text in notEnvelopes {
            #expect(!PendingRunEnvelope.isRendered(text: text))
        }
    }
}
