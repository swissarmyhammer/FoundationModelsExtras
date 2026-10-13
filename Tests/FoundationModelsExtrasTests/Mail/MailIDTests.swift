import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``MailID`` and ``SignalID`` are ULID newtypes that encode as one ULID
/// string.
@Suite("MailID and SignalID: ULID ids that encode as one string")
struct MailIDTests {
    @Test("two new mail ids are different")
    func twoNewMailIDsAreDifferent() {
        #expect(MailID() != MailID())
    }

    @Test("two new signal ids are different")
    func twoNewSignalIDsAreDifferent() {
        #expect(SignalID() != SignalID())
    }

    @Test("an id made from a ULID keeps that ULID, and its description is the ULID string")
    func anIDKeepsItsULID() {
        let ulid = ULID()

        #expect(MailID(ulid).value == ulid)
        #expect(MailID(ulid).description == ulid.ulidString)
        #expect(SignalID(ulid).value == ulid)
        #expect(SignalID(ulid).description == ulid.ulidString)
    }

    @Test("a mail id and a signal id survive a JSON round trip")
    func theIDsSurviveARoundTrip() throws {
        let mailID = MailID()
        let signalID = SignalID()

        #expect(try JSONDecoder().decode(MailID.self, from: JSONEncoder().encode(mailID)) == mailID)
        #expect(try JSONDecoder().decode(SignalID.self, from: JSONEncoder().encode(signalID)) == signalID)
    }

    @Test("the JSON of an id is the plain ULID string, not an object")
    func theJSONIsAPlainString() throws {
        let ulid = ULID()

        let mailJSON = try String(decoding: JSONEncoder().encode(MailID(ulid)), as: UTF8.self)
        let signalJSON = try String(decoding: JSONEncoder().encode(SignalID(ulid)), as: UTF8.self)

        #expect(mailJSON == "\"\(ulid.ulidString)\"")
        #expect(signalJSON == "\"\(ulid.ulidString)\"")
    }
}
