import Foundation
import FoundationModelsExtras
import Testing

/// Behavioral tests for the doctor report of `doctor-plan.md` §4 and §5: the
/// worst status of the findings, the exit code a script reads, and the JSON
/// form the `--json` output writes.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
@Suite("Doctor report") struct DoctorReportTests {

    /// A report holding one finding of each status, in the order stated here.
    ///
    /// - Returns: A report of three findings: passing, needing attention, and
    ///   broken.
    private static func threeStatusReport() -> DoctorReport {
        DoctorReport(checks: [
            DoctorTestSupport.finding(.ok, name: "configuration"),
            DoctorTestSupport.finding(.warning, name: "transcripts"),
            DoctorTestSupport.finding(.error, name: "model"),
        ])
    }

    // MARK: - The exit codes of doctor-plan.md §5

    @Test func `a report of only passing checks exits zero`() {
        let report = DoctorReport(checks: [DoctorTestSupport.finding(.ok, name: "configuration")])
        #expect(report.worstStatus == .ok)
        #expect(report.exitCode == DoctorTestSupport.passingExitCode)
    }

    @Test func `a report holding an error exits one`() {
        let report = DoctorReport(checks: [
            DoctorTestSupport.finding(.ok, name: "configuration"),
            DoctorTestSupport.finding(.error, name: "model"),
        ])
        #expect(report.worstStatus == .error)
        #expect(report.exitCode == DoctorTestSupport.brokenExitCode)
    }

    @Test func `an error outranks a warning`() {
        let report = DoctorReport(checks: [
            DoctorTestSupport.finding(.warning, name: "transcripts"),
            DoctorTestSupport.finding(.error, name: "model"),
        ])
        #expect(report.worstStatus == .error)
        #expect(report.exitCode == DoctorTestSupport.brokenExitCode)
    }

    @Test func `a report holding only a warning exits five`() {
        let report = DoctorReport(checks: [
            DoctorTestSupport.finding(.ok, name: "configuration"),
            DoctorTestSupport.finding(.warning, name: "transcripts"),
        ])
        #expect(report.worstStatus == .warning)
        #expect(report.exitCode == DoctorTestSupport.attentionExitCode)
    }

    // MARK: - The JSON a script reads

    @Test func `a report survives a json round trip`() throws {
        let report = Self.threeStatusReport()

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)

        #expect(decoded == report)
    }

    /// The `--json` output is one array of findings (doctor-plan.md §6), so the
    /// report encodes as that array and not as an object that wraps it.
    @Test func `an encoded report is the array of its checks`() throws {
        let report = Self.threeStatusReport()

        let data = try JSONEncoder().encode(report)
        let checks = try JSONDecoder().decode([HealthCheck].self, from: data)

        #expect(checks == report.checks)
    }

    @Test func `a report decodes from its own json data`() throws {
        let report = Self.threeStatusReport()

        let decoded = try JSONDecoder().decode(DoctorReport.self, from: report.jsonData())

        #expect(decoded == report)
    }
}
