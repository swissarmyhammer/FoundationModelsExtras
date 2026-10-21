import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``SessionSendReceipt`` reports the result of a send for one target.
@Suite("SessionSendReceipt: the result of a send for one target")
struct SessionSendReceiptTests {
    @Test(
        "each receipt survives a JSON round trip",
        arguments: [
            SessionSendReceipt(messageID: MailID(), target: ULID(), outcome: .delivered),
            SessionSendReceipt(messageID: MailID(), target: ULID(), outcome: .queued),
            SessionSendReceipt(messageID: MailID(), target: ULID(), outcome: .started),
            SessionSendReceipt(outcome: .refused, reason: "no live root session has this working folder"),
        ])
    func eachReceiptSurvivesARoundTrip(receipt: SessionSendReceipt) throws {
        #expect(try SessionFixtures.roundTrip(receipt) == receipt)
    }

    @Test("a refused receipt with no match has no message id, no target and no reason by default")
    func theOptionalFieldsDefaultToNil() {
        let receipt = SessionSendReceipt(outcome: .refused)

        #expect(receipt.messageID == nil)
        #expect(receipt.target == nil)
        #expect(receipt.reason == nil)
    }
}
