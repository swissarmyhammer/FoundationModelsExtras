@testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// ``OperationEventSink/postToolCallReport(closing:attachments:)`` gives a
/// ``ToolCallReport`` to a sink that is also a ``ToolCallReportSink``, and
/// drops it on any other sink.
@Suite("ToolCallReport: the records that one tool call attached")
struct ToolCallReportTests {
    /// The records of one test call, in call order.
    private static let attachmentsInCallOrder = [
        ToolCallAttachment(schemaName: "FileChangeSet", contentJSON: #"{"files":["a.swift"]}"#),
        ToolCallAttachment(schemaName: "FileChangeSet", contentJSON: #"{"files":["b.swift"]}"#),
    ]

    /// A sink that keeps each report that it gets.
    private actor ReportRecordingSink: OperationEventSink, ToolCallReportSink {
        /// The reports, in the order they came.
        private(set) var reports: [ToolCallReport] = []

        /// Ignores the event.
        func post(event: OperationEvent) async {}

        /// Keeps the report.
        func post(report: ToolCallReport) async {
            reports.append(report)
        }
    }

    /// A sink that is not a ``ToolCallReportSink``. It keeps each event and
    /// each record that it gets.
    private actor PlainSink: OperationEventSink {
        /// The events, in the order they came.
        private(set) var events: [OperationEvent] = []

        /// The records, in the order they came.
        private(set) var invocations: [ToolInvocationRecord] = []

        /// Keeps the event.
        func post(event: OperationEvent) async {
            events.append(event)
        }

        /// Keeps the record.
        func post(invocation record: ToolInvocationRecord) async {
            invocations.append(record)
        }
    }

    /// The close record of one call, with a new identity.
    ///
    /// - Returns: The close record.
    private static func makeClosedRecord() -> ToolInvocationRecord {
        ToolInvocationRecord(
            tool: "search", op: "search", correlationID: ULID().ulidString,
            sessionID: ULID(), openedAt: Date()
        ).closed(at: Date())
    }

    @Test("postToolCallReport(closing:attachments:) posts one report with the close record's identity to a ToolCallReportSink")
    func sharedReportPostDeliversToAReportSink() async throws {
        let recording = ReportRecordingSink()
        // The type that a decorator holds, so the call goes through the cast.
        let sink: any OperationEventSink = recording
        let close = Self.makeClosedRecord()

        await sink.postToolCallReport(closing: close, attachments: Self.attachmentsInCallOrder)

        let reports = await recording.reports
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.correlationID == close.correlationID)
        #expect(report.tool == close.tool)
        #expect(report.op == close.op)
        #expect(report.sessionID == close.sessionID)
        #expect(report.attachments == Self.attachmentsInCallOrder)
    }

    @Test("postToolCallReport(closing:attachments:) posts nothing for a call that attached nothing")
    func sharedReportPostSkipsACallWithNoAttachments() async {
        let recording = ReportRecordingSink()
        let sink: any OperationEventSink = recording

        await sink.postToolCallReport(closing: Self.makeClosedRecord(), attachments: [])

        #expect(await recording.reports.isEmpty)
    }

    @Test("postToolCallReport(closing:attachments:) drops the report on a sink that is not a ToolCallReportSink, without a trap")
    func sharedReportPostDropsOnAPlainSink() async {
        let plain = PlainSink()
        let sink: any OperationEventSink = plain

        await sink.postToolCallReport(closing: Self.makeClosedRecord(), attachments: Self.attachmentsInCallOrder)

        #expect(await plain.events.isEmpty)
        #expect(await plain.invocations.isEmpty)
    }

    @Test("an attachment survives a JSON round trip")
    func anAttachmentRoundTrips() throws {
        let attachment = try #require(Self.attachmentsInCallOrder.first)

        let data = try JSONEncoder().encode(attachment)

        #expect(try JSONDecoder().decode(ToolCallAttachment.self, from: data) == attachment)
    }

    @Test("a run kind encodes as its raw value", arguments: [RunKind.swiftTask, .process])
    func aRunKindEncodesAsItsRawValue(_ kind: RunKind) throws {
        let data = try JSONEncoder().encode(kind)

        #expect(String(decoding: data, as: UTF8.self) == "\"\(kind.rawValue)\"")
        #expect(try JSONDecoder().decode(RunKind.self, from: data) == kind)
    }
}
