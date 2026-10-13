import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``MailSender`` and ``MailBody`` encode each case, and each body has its
/// ``MailKind``.
@Suite("MailSender and MailBody: each case encodes, and each body has its kind")
struct MailBodyTests {
    /// One body of each case.
    static let bodies: [MailBody] = [
        .userMessage(prompt: "Hello", options: UserMessageOptions(maxTokens: 128, mode: .stream)),
        .runEvent(
            OperationEvent(
                tool: "shell", op: "run command", correlationID: ULID().ulidString,
                kind: .completed, detail: "{\"exit\":0}", outcome: .succeeded)),
        .elicitationAnswer(id: ULID(), response: .accept(content: ["name": .string("Ada")])),
        .elicitationAnswer(id: ULID(), response: .decline),
        .agentMessage(from: ULID(), content: "The child is done."),
    ]

    /// One sender of each case.
    static let senders: [MailSender] = [
        .user,
        .run(correlationID: ULID().ulidString),
        .elicitation(ULID()),
        .session(ULID()),
    ]

    @Test("each body survives a JSON round trip", arguments: bodies)
    func eachBodySurvivesARoundTrip(body: MailBody) throws {
        let decoded = try JSONDecoder().decode(MailBody.self, from: JSONEncoder().encode(body))

        #expect(decoded == body)
    }

    @Test("each sender survives a JSON round trip", arguments: senders)
    func eachSenderSurvivesARoundTrip(sender: MailSender) throws {
        let decoded = try JSONDecoder().decode(MailSender.self, from: JSONEncoder().encode(sender))

        #expect(decoded == sender)
    }

    @Test("each body gives the kind of its case")
    func eachBodyGivesItsKind() {
        #expect(Self.bodies.map(\.kind) == [
            .userMessage, .runEvent, .elicitationAnswer, .elicitationAnswer, .agentMessage,
        ])
    }

    @Test("each mail kind has its fixed raw value")
    func eachKindHasItsRawValue() {
        #expect(MailKind.allCases.map(\.rawValue) == [
            "user_message", "run_event", "elicitation_answer", "agent_message",
        ])
    }
}
