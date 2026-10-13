import Foundation
@testable import FoundationModelsExtras
import Testing

/// ``Origin`` names the mail, the signal or the session work that caused an
/// output event.
@Suite("Origin: the mail, the signal or the system work of an event")
struct OriginTests {
    @Test(
        "each origin survives a JSON round trip",
        arguments: [
            Origin.mail([MailID(), MailID()]),
            Origin.mail([]),
            Origin.signal(SignalID()),
            Origin.system,
        ])
    func eachOriginSurvivesARoundTrip(origin: Origin) throws {
        let decoded = try JSONDecoder().decode(Origin.self, from: JSONEncoder().encode(origin))

        #expect(decoded == origin)
    }

    @Test("two mail origins with the same ids in a different order are equal")
    func theOrderOfTheMailIDsDoesNotMatter() {
        let first = MailID()
        let second = MailID()

        #expect(Origin.mail(Set([first, second])) == Origin.mail(Set([second, first])))
        #expect(Origin.mail([first, second]).hashValue == Origin.mail([second, first]).hashValue)
    }

    @Test("a mail origin is not equal to a mail origin with other ids")
    func otherMailIDsAreNotEqual() {
        #expect(Origin.mail([MailID()]) != Origin.mail([MailID()]))
    }
}
