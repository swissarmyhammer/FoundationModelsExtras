import Foundation
import FoundationModelsExtras
import Testing
import ULID

/// Holds ``ToolCallReport/init(closing:attachments:)`` and
/// ``RunPlane/wait(completionToken:seconds:)`` to the public surface. A host
/// outside this package makes the report of a closed call with the
/// initializer, and waits for a background run with `wait`.
///
/// The import is plain, with no `@testable`. When one of the two loses
/// `public`, this file does not compile. That is the assertion that matters,
/// because the caller is in another package, where `@testable` is not
/// available.
@Suite("ToolCallReport.init(closing:) and RunPlane.wait over a plain import")
struct ToolCallReportAndWaitPublicSurfaceTests {
    /// The records of one test call, in call order.
    private static let attachmentsInCallOrder = [
        ToolCallAttachment(schemaName: "FileChangeSet", contentJSON: #"{"files":["a.swift"]}"#),
        ToolCallAttachment(schemaName: "FileChangeSet", contentJSON: #"{"files":["b.swift"]}"#),
    ]

    /// The close record of one call, with a new identity.
    ///
    /// - Returns: The close record.
    private static func makeClosedRecord() -> ToolInvocationRecord {
        ToolInvocationRecord(
            tool: "search", op: "search files", correlationID: ULID().ulidString,
            sessionID: ULID(), openedAt: Date()
        ).closed(at: Date())
    }

    // MARK: - ToolCallReport

    @Test("the report of a closed call has the identity of the record and the attachments in call order")
    func theReportHasTheIdentityOfTheRecord() throws {
        let record = Self.makeClosedRecord()

        let report = try #require(ToolCallReport(closing: record, attachments: Self.attachmentsInCallOrder))

        #expect(report.tool == record.tool)
        #expect(report.op == record.op)
        #expect(report.correlationID == record.correlationID)
        #expect(report.sessionID == record.sessionID)
        #expect(report.attachments == Self.attachmentsInCallOrder)
    }

    @Test("a closed call that attached nothing makes no report")
    func aCallWithNoAttachmentMakesNoReport() {
        #expect(ToolCallReport(closing: Self.makeClosedRecord(), attachments: []) == nil)
    }

    // MARK: - RunPlane.wait

    @Test("a wait for a token that names no run returns unknownToken at once")
    func aWaitForAnUnknownTokenReturnsUnknownToken() async {
        let runPlane = RunPlane()

        let outcome = await runPlane.wait(completionToken: RunPlane.makeCompletionToken(), seconds: nil)

        #expect(outcome == .unknownToken)
    }
}
