import Foundation
import FoundationModelsExtras
import Testing

/// The wire form of ``OperationValue`` and ``OperationResult``, and the
/// optional `value` of ``OperationEvent``.
@Suite("OperationValue and OperationResult: the wire form")
struct OperationResultTests {
    /// A shell exit code, as a tool reports it.
    private static let exitCode = 2

    /// An event as a recorder wrote it before ``OperationEvent/value``
    /// existed: a terminal event with no `value` key.
    private static let olderCompletedJSON = """
        {"tool": "shell", "op": "run command", "correlationID": "01ARZ3NDEKTSV4RRFFQ69G5FAV", \
        "kind": "completed", "detail": "out", "outcome": "failed"}
        """

    /// Encodes `value`, then decodes the data as the same type.
    private static func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    /// The value of each kind, with the nested object.
    private static let eachKind: [OperationValue] = [
        .int(exitCode),
        .string("denied"),
        .bool(true),
        .object(["code": .int(exitCode), "nested": .object(["ok": .bool(false)])]),
    ]

    @Test("a value of each kind round-trips through Codable", arguments: eachKind)
    func aValueRoundTrips(value: OperationValue) throws {
        #expect(try Self.roundTrip(value) == value)
    }

    @Test("an int value is a bare JSON number on the wire")
    func anIntIsABareNumber() throws {
        let json = try String(decoding: JSONEncoder().encode(OperationValue.int(Self.exitCode)), as: UTF8.self)

        #expect(json == "\(Self.exitCode)")
    }

    @Test("a bare JSON boolean decodes as a bool value")
    func aBareBooleanDecodesAsABool() throws {
        let decoded = try JSONDecoder().decode(OperationValue.self, from: Data("true".utf8))

        #expect(decoded == .bool(true))
    }

    @Test("a result with a value round-trips through Codable")
    func aResultWithAValueRoundTrips() throws {
        let result = OperationResult(outcome: .failed, value: .int(Self.exitCode))

        #expect(try Self.roundTrip(result) == result)
    }

    @Test("a result with no value round-trips through Codable")
    func aResultWithNoValueRoundTrips() throws {
        let result = OperationResult(outcome: .succeeded, value: nil)

        #expect(try Self.roundTrip(result) == result)
    }

    @Test("an event with a value round-trips through Codable")
    func anEventWithAValueRoundTrips() throws {
        let event = OperationEvent(
            tool: "shell", op: "run command", correlationID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            kind: .completed, detail: "out", outcome: .failed, value: .int(Self.exitCode))

        #expect(try Self.roundTrip(event) == event)
    }

    @Test("an event with no value has no value key on the wire")
    func anEventWithNoValueWritesNoKey() throws {
        let event = OperationEvent(
            tool: "shell", op: "run command", correlationID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            kind: .completed, detail: "out", outcome: .succeeded)

        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])

        #expect(object["value"] == nil)
    }

    @Test("an event recorded before the value field existed decodes with a nil value")
    func anOlderEventDecodesWithNoValue() throws {
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: Data(Self.olderCompletedJSON.utf8))

        #expect(decoded.value == nil)
    }
}
