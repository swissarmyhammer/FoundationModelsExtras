import Foundation
import FoundationModelsExtras
import Testing

/// The wire form of a `.message` event, and the decode of an event that was
/// recorded before the `.message` kind existed.
@Suite("OperationEvent: the message kind on the wire")
struct OperationEventMessageTests {
    /// The wire value of the `.message` kind.
    private static let messageWireValue = "message"

    /// A `.progress` event as a recorder wrote it before the `.message` kind
    /// existed: no `outcome` key and no `elicitation` key.
    private static let olderProgressJSON = """
        {"tool": "agents", "op": "start agent", "correlationID": "01ARZ3NDEKTSV4RRFFQ69G5FAV", \
        "kind": "progress", "detail": "halfway"}
        """

    @Test("a .message event round-trips through Codable, with the text as its detail and no outcome")
    func aMessageEventRoundTrips() throws {
        let event = OperationEvent(
            tool: "agents", op: "start agent", correlationID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            kind: .message, detail: "the child found the file")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded == event)
        #expect(decoded.kind == .message)
        #expect(decoded.detail == "the child found the file")
        #expect(decoded.outcome == nil)
        #expect(object["kind"] as? String == Self.messageWireValue)
    }

    @Test("an event recorded before the message kind decodes unchanged")
    func anOlderEventDecodesUnchanged() throws {
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: Data(Self.olderProgressJSON.utf8))

        #expect(
            decoded
                == OperationEvent(
                    tool: "agents", op: "start agent", correlationID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                    kind: .progress, detail: "halfway"))
    }
}
