import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``Mail`` carries its id, its sender and its body.
@Suite("Mail: an id, a sender and a body")
struct MailTests {
    /// A body for the tests.
    private static let body = MailBody.userMessage(prompt: "Hello", options: UserMessageOptions())

    @Test("a mail with no id gets a new id each time")
    func theDefaultIDIsNewEachTime() {
        let first = Mail(sender: .user, body: Self.body)
        let second = Mail(sender: .user, body: Self.body)

        #expect(first.id != second.id)
    }

    @Test("a mail keeps the id that the caller gives")
    func aGivenIDIsKept() {
        let id = MailID()

        #expect(Mail(id: id, sender: .user, body: Self.body).id == id)
    }

    @Test("a mail survives a JSON round trip")
    func aMailSurvivesARoundTrip() throws {
        let mail = Mail(
            sender: .session(ULID()),
            body: .agentMessage(from: ULID(), content: "Please continue."))

        let decoded = try JSONDecoder().decode(Mail.self, from: JSONEncoder().encode(mail))

        #expect(decoded == mail)
    }

    @Test("the mail of a catalog notice has the catalog as sender and the notice as body")
    func theMailOfACatalogNotice() {
        let notice = CatalogChangeNotice(
            kind: .skills, added: [CatalogEntry(name: "x", description: "does x")], removed: [], changed: [])
        let id = MailID()

        let mail = Mail(id: id, catalogNotice: notice)

        #expect(mail.id == id)
        #expect(mail.sender == .catalog(.skills))
        #expect(mail.body == .catalogChange(notice))
        #expect(mail.body.kind == .catalogChange)
        #expect(Mail(catalogNotice: notice).id != Mail(catalogNotice: notice).id)
    }
}
