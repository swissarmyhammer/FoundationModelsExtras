import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// ``InMemorySessionDirectory/mail(carrying:)`` follows the body-choice rule
/// and the sender-header rule of ``SessionDirectory/send(_:)``.
@Suite("In-memory session directory: mail")
struct InMemorySessionDirectoryMailTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    @Test("the mail of a user message with a source session starts with a header that names the source session")
    func aUserMessageWithASourceSessionHasASourceHeader() {
        let directory = Fixtures.makeDirectory()
        let source = SessionFixtures.summary()
        directory.register(source)
        let message = SessionMessage(
            id: MailID(), from: Fixtures.user, to: ULID(), text: "Hi.", sourceSession: source.id,
            sentAt: Fixtures.now, chainDepth: 1)

        let mail = directory.mail(carrying: message)

        let content = "From the user, in Fix the build (/tmp/project)\n\nHi."
        #expect(
            mail
                == Mail(
                    id: message.id, sender: .user, body: .userMessage(prompt: content, options: UserMessageOptions())))
    }

    @Test("the mail of a user message with no source session has no header")
    func aUserMessageWithNoSourceSessionHasNoHeader() {
        let directory = Fixtures.makeDirectory()
        let message = SessionMessage(
            id: MailID(), from: Fixtures.user, to: ULID(), text: "Hi.", sentAt: Fixtures.now, chainDepth: 1)

        let mail = directory.mail(carrying: message)

        #expect(
            mail
                == Mail(id: message.id, sender: .user, body: .userMessage(prompt: "Hi.", options: UserMessageOptions()))
        )
    }

    @Test("the mail of a session message starts with a header with the title, the agent and the folder of the sender")
    func aSessionMessageHasASenderHeader() {
        let directory = Fixtures.makeDirectory()
        let sender = SessionFixtures.summary()
        directory.register(sender)
        let message = SessionMessage(
            id: MailID(), from: .session(sender.id), to: ULID(), text: "Done.", sentAt: Fixtures.now, chainDepth: 2)

        let mail = directory.mail(carrying: message)

        let content = "From the session Fix the build, agent Default agent (/tmp/project)\n\nDone."
        #expect(
            mail
                == Mail(
                    id: message.id, sender: .session(sender.id), body: .agentMessage(from: sender.id, content: content))
        )
    }

    @Test("the header of a sender that the directory does not know names the session id")
    func anUnknownSenderHeaderNamesTheID() {
        let directory = Fixtures.makeDirectory()
        let sender = ULID()
        let message = SessionMessage(
            id: MailID(), from: .session(sender), to: ULID(), text: "Done.", sentAt: Fixtures.now, chainDepth: 2)

        let mail = directory.mail(carrying: message)

        let content = "From the session \(sender.ulidString)\n\nDone."
        #expect(mail.body == .agentMessage(from: sender, content: content))
    }

    @Test("the header of a source session that the directory does not know names the session id")
    func anUnknownSourceHeaderNamesTheID() {
        let directory = Fixtures.makeDirectory()
        let source = ULID()
        let message = SessionMessage(
            id: MailID(), from: Fixtures.user, to: ULID(), text: "Hi.", sourceSession: source,
            sentAt: Fixtures.now, chainDepth: 1)

        let mail = directory.mail(carrying: message)

        let content = "From the user, in the session \(source.ulidString)\n\nHi."
        #expect(mail.body == .userMessage(prompt: content, options: UserMessageOptions()))
    }

    @Test("the header of a sender with no title names its short id, and with no agent name its agent id")
    func aSenderWithNoTitleAndNoAgentNameHasAShortIDHeader() {
        let directory = Fixtures.makeDirectory()
        var sender = SessionFixtures.summary()
        sender.title = nil
        sender.agentName = nil
        directory.register(sender)
        let message = SessionMessage(
            id: MailID(), from: .session(sender.id), to: ULID(), text: "Done.", sentAt: Fixtures.now, chainDepth: 2)

        let mail = directory.mail(carrying: message)

        let content = "From the session \(sender.shortID), agent default (/tmp/project)\n\nDone."
        #expect(mail.body == .agentMessage(from: sender.id, content: content))
    }
}
