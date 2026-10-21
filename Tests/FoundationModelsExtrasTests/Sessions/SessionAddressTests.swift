import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``SessionAddress`` names the targets of a message, and
/// ``SessionMessageSender`` names its sender.
@Suite("SessionAddress and SessionMessageSender: the two ends of a message")
struct SessionAddressTests {
    @Test(
        "each address survives a JSON round trip",
        arguments: [
            SessionAddress.session(ULID()),
            .agent(id: "reviewer", folder: SessionFixtures.folder),
            .agent(id: "reviewer", folder: nil),
            .folder(SessionFixtures.folder),
            .tag("build"),
        ])
    func eachAddressSurvivesARoundTrip(address: SessionAddress) throws {
        #expect(try SessionFixtures.roundTrip(address) == address)
    }

    @Test(
        "each sender survives a JSON round trip",
        arguments: [
            SessionMessageSender.session(ULID()),
            .user(clientID: "testudo-window-1"),
        ])
    func eachSenderSurvivesARoundTrip(sender: SessionMessageSender) throws {
        #expect(try SessionFixtures.roundTrip(sender) == sender)
    }
}
