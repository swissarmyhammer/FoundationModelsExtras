@testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the check of ``ToolContext/elicit(_:)`` on an accepted form
/// answer: an answer that does not agree with the requested schema reaches
/// the run as a decline that tells why, and with no content.
///
/// Each test answers through a ``MountFixtures/ImmediatelyRespondingSink``,
/// which gives the answer to the run plane from inside the post of the
/// question. Thus the question ends before `elicit` waits, and no test uses
/// a clock, a sleep, a poll, a retry or a time limit.
@Suite("ToolContext: an accepted form answer that is not valid reaches the run as a decline")
struct ToolContextAnswerValidationTests {
    /// The pattern of a five-digit postal code.
    private static let zipPattern = "^[0-9]{5}$"

    /// A form question with one required field, `zip`, that must match
    /// ``zipPattern``.
    private static func zipRequest() -> ElicitationRequest {
        ElicitationRequest(
            message: "What is your postal code?",
            elicitationId: ULID(),
            requestedSchema: ElicitationRequestedSchema(
                properties: ["zip": .string(ElicitationStringSchema(pattern: zipPattern))], required: ["zip"])
        )
    }

    /// Asks `request` through a context whose sink gives `response` at once,
    /// and gives the answer that the run got.
    ///
    /// - Parameters:
    ///   - response: The answer of the user.
    ///   - request: The question.
    /// - Returns: The answer that `elicit` gave to the run.
    private static func answer(
        _ response: ElicitationResponse, to request: ElicitationRequest
    ) async throws -> ElicitationResponse {
        let runPlane = RunPlane()
        let context = ToolContext(
            sessionID: ULID(),
            runPlane: runPlane,
            sink: MountFixtures.ImmediatelyRespondingSink(runPlane: runPlane, response: response),
            tool: "host",
            op: "ask user",
            completionToken: RunPlane.makeCompletionToken(),
            isCancelled: { false })
        return try await context.elicit(request)
    }

    @Test("an accepted form answer that does not match the pattern reaches the run as a decline with the reason")
    func anInvalidAnswerBecomesADecline() async throws {
        let answer = try await Self.answer(.accept(content: ["zip": .string("1234")]), to: Self.zipRequest())

        #expect(answer.action == .decline)
        #expect(answer.content == nil)
        #expect(
            answer.reason
                == #"the answer is not valid: the field "zip" does not match the pattern "^[0-9]{5}$""#)
    }

    @Test("an accepted form answer with no content and a required field reaches the run as a decline")
    func anAnswerWithNoContentBecomesADecline() async throws {
        let answer = try await Self.answer(.accept(content: nil), to: Self.zipRequest())

        #expect(
            answer
                == .decline(
                    reason: ElicitationRequestedSchema.invalidAnswerReasonPrefix
                        + #"the field "zip" is required, and the answer does not give it"#))
    }

    @Test("a valid accepted form answer reaches the run as an accept with its content")
    func aValidAnswerStaysAnAccept() async throws {
        let accepted = ElicitationResponse.accept(content: ["zip": .string("12345")])

        #expect(try await Self.answer(accepted, to: Self.zipRequest()) == accepted)
    }

    @Test("an accept of a URL question is not checked")
    func aURLAcceptIsNotChecked() async throws {
        let request = ElicitationRequest(
            message: "Sign in to the server",
            elicitationId: ULID(),
            url: try #require(URL(string: "https://example.com/sign-in"))
        )
        let accepted = ElicitationResponse.accept(content: ["code": .string("not in a schema")])

        #expect(try await Self.answer(accepted, to: request) == accepted)
    }
}
