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
    /// wait-tool text that made the model loop, the turn language of the
    /// old text, and the empty output that the old text asked for.
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
        "starts you working again",
        "end your answer",
        "do nothing",
        "write no text",
    ]

    /// Asserts that `text` has none of the forbidden fragments, and not the
    /// word "turn".
    private static func expectNoTurnLanguage(in text: String) {
        for fragment in forbiddenDefaultCollectInstructionFragments {
            #expect(!text.contains(fragment), "text must not say \(fragment): \(text)")
        }
        let words = text.lowercased().split { !$0.isLetter }
        #expect(!words.contains("turn"), "text must not say turn: \(text)")
        #expect(!words.contains("turns"), "text must not say turns: \(text)")
    }

    /// The pending-work text that the user approved, word for word.
    private static let approvedPendingWorkInstruction =
        "Its result will arrive in this conversation as a message when it is ready. You do not need "
        + "to wait for it or check on it, and no tool can make it come sooner. Go on with any work "
        + "that does not need it. If none is left, post your status as plain text: what you wait on "
        + "and its completion token."

    @Test("pendingWorkInstruction is the approved text, word for word")
    func pendingWorkInstructionIsTheApprovedText() {
        #expect(PendingRunEnvelope.pendingWorkInstruction == Self.approvedPendingWorkInstruction)
        Self.expectNoTurnLanguage(in: PendingRunEnvelope.pendingWorkInstruction)
    }

    @Test("the waiting text of one call names it with its token, and its status line is Waiting on the call")
    func waitingStatusInstructionOfOneCallIsTheApprovedText() {
        let completionToken = ULID().ulidString

        let text = PendingRunEnvelope.waitingStatusInstruction(
            for: [(description: "execute python tests/runtests.py", completionToken: completionToken)])

        #expect(
            text
                == "Running in the background: execute python tests/runtests.py (completion token "
                + "\"\(completionToken)\"). Its result will arrive in this conversation as a message when "
                + "it is ready. You do not need to wait for it or check on it, and no tool can make it come "
                + "sooner. Go on with any work that does not need it. If none is left, post your status as "
                + "plain text: `Waiting on execute python tests/runtests.py (\(completionToken)).`"
        )
        Self.expectNoTurnLanguage(in: text)
    }

    @Test("the waiting text of several calls names each with its token, in order, and its status line lists them all")
    func waitingStatusInstructionOfSeveralCallsNamesEachCall() {
        let first = ULID().ulidString
        let second = ULID().ulidString

        let text = PendingRunEnvelope.waitingStatusInstruction(
            for: [(description: "agent coder", completionToken: first), (description: "execute make", completionToken: second)])

        #expect(
            text
                == "Running in the background: agent coder (completion token \"\(first)\"); execute make "
                + "(completion token \"\(second)\"). Their results will arrive in this conversation as "
                + "messages when they are ready. You do not need to wait for them or check on them, and no "
                + "tool can make them come sooner. Go on with any work that does not need them. If none is "
                + "left, post your status as plain text: `Waiting on agent coder (\(first)); execute make "
                + "(\(second)).`"
        )
        Self.expectNoTurnLanguage(in: text)
    }

    @Test("the waiting text of no open call says nothing runs in the background and asks for a status")
    func waitingStatusInstructionOfNoCallSaysNothingRuns() {
        let text = PendingRunEnvelope.waitingStatusInstruction(for: [])

        #expect(
            text == "Nothing is running in the background. If no work is left, post your status as plain text.")
        Self.expectNoTurnLanguage(in: text)
    }

    @Test("the default next sentence is the waiting text of the one call it describes")
    func defaultCollectInstructionIsTheWaitingTextOfItsCall() {
        let completionToken = ULID().ulidString

        #expect(
            PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken, describing: "agent coder")
                == PendingRunEnvelope.waitingStatusInstruction(
                    for: [(description: "agent coder", completionToken: completionToken)])
        )
    }

    @Test("with only a token, the default next sentence names the call as this call")
    func defaultCollectInstructionWithOnlyATokenNamesThisCall() {
        let completionToken = ULID().ulidString

        #expect(
            PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
                == PendingRunEnvelope.waitingStatusInstruction(
                    for: [(description: "this call", completionToken: completionToken)])
        )
    }

    @Test("the default next sentence says: the call runs in the background with its token, the result arrives as a message, no tool makes it come sooner, and a status names what it waits on")
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
                // The call goes on behind the answer, under its real token.
                "Running in the background",
                completionToken,
                // The result comes in as a message.
                "will arrive in this conversation as a message",
                // No tool makes it come sooner.
                "no tool can make it come sooner",
                // With no other work, the model posts a status, not nothing.
                "post your status as plain text",
                "Waiting on this call (\(completionToken)).",
            ]
        )
        Self.expectNoTurnLanguage(in: next)
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
