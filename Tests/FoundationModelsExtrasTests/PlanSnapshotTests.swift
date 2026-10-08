import Foundation
import FoundationModelsExtras
import Testing

/// The wire form of a ``PlanSnapshot``, and of an `OperationEvent` that
/// carries one or that was recorded before the `plan` field existed.
@Suite("PlanSnapshot: the agent plan on the wire")
struct PlanSnapshotTests {
    /// The wire value of ``PlanSnapshot/Status/inProgress``. It agrees with ACP.
    private static let inProgressWireValue = "in_progress"

    /// The correlation of each fixture event.
    private static let correlationID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    /// The short text line for the model on each fixture event.
    private static let progressLine = "3 of 7 tasks done"

    /// A `.progress` event as a recorder wrote it before the `plan` field
    /// existed: no `outcome`, `elicitation` or `plan` key.
    private static let olderProgressJSON = """
        {"tool": "tasks", "op": "run plan", "correlationID": "\(correlationID)", \
        "kind": "progress", "detail": "\(progressLine)"}
        """

    /// A plan with one entry in each status.
    private static func snapshot() -> PlanSnapshot {
        PlanSnapshot(
            id: "plan-1",
            entries: [
                PlanSnapshot.Entry(content: "read the spec", priority: .high, status: .completed),
                PlanSnapshot.Entry(content: "write the code", priority: .medium, status: .inProgress),
                PlanSnapshot.Entry(content: "run the tests", priority: .low, status: .pending),
                PlanSnapshot.Entry(content: "ship it", priority: .low, status: .cancelled),
            ]
        )
    }

    @Test("a plan round-trips through Codable")
    func aPlanRoundTrips() throws {
        let plan = Self.snapshot()

        let decoded = try JSONDecoder().decode(PlanSnapshot.self, from: try JSONEncoder().encode(plan))

        #expect(decoded == plan)
    }

    @Test("inProgress encodes as \"in_progress\"")
    func inProgressEncodesAsTheACPWireValue() throws {
        let entry = PlanSnapshot.Entry(content: "write the code", priority: .medium, status: .inProgress)

        let data = try JSONEncoder().encode(entry)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["status"] as? String == Self.inProgressWireValue)
    }

    @Test("an event recorded with no plan key decodes with no plan")
    func anOlderEventDecodesWithNoPlan() throws {
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: Data(Self.olderProgressJSON.utf8))

        #expect(decoded.plan == nil)
        #expect(decoded.kind == .progress)
        #expect(decoded.detail == Self.progressLine)
    }

    @Test("an event with a plan round-trips through Codable")
    func anEventWithAPlanRoundTrips() throws {
        let plan = Self.snapshot()
        let event = OperationEvent(
            tool: "tasks", op: "run plan", correlationID: Self.correlationID,
            kind: .progress, detail: Self.progressLine, plan: plan)

        let decoded = try JSONDecoder().decode(OperationEvent.self, from: try JSONEncoder().encode(event))

        #expect(decoded == event)
        #expect(decoded.plan == plan)
    }
}
