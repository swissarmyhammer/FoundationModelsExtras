import Foundation
import FoundationModelsExtras
import Testing

/// Behavioral tests for the doctor vocabulary of `doctor-plan.md` §4: the
/// `HealthStatus` levels, the `HealthCheck` finding and its three factory
/// functions, and the default implementations the `Doctorable` protocol gives.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
@Suite("Doctor health-check vocabulary") struct DoctorableTests {

    /// A component that states only the two members `Doctorable` requires, so
    /// every assertion below measures the protocol extension's own defaults
    /// and nothing the component wrote.
    private struct MinimalComponent: Doctorable {
        let doctorName = "minimal"
        let doctorCategory = "probe"
    }

    /// A passing finding the JSON tests encode. Its `fix` is `nil`, which is
    /// what makes the absent-key assertion meaningful.
    private static let okCheck = HealthCheck.ok(
        name: "configuration",
        message: "the configuration loaded",
        category: "configuration")

    /// A finding that needs attention, carrying the action that answers it.
    private static let warningCheck = HealthCheck.warning(
        name: "transcripts",
        message: "the transcripts directory does not exist",
        fix: "mkdir -p ~/.config/extras/transcripts",
        category: "storage")

    /// A broken finding, carrying the command that repairs it.
    private static let errorCheck = HealthCheck.error(
        name: "model",
        message: "the model reference does not resolve",
        fix: "extras model download default",
        category: "model")

    /// Asserts that `check` reports `status` and carries `fix` word for word.
    ///
    /// - Parameters:
    ///   - check: The finding to read.
    ///   - status: The level the factory was expected to set.
    ///   - fix: The action the call site gave the factory.
    private func expectFinding(_ check: HealthCheck, reports status: HealthStatus, fix: String) {
        #expect(check.status == status)
        #expect(check.fix == fix)
    }

    /// Encodes `check`, decodes the bytes back, and asserts the value survived.
    ///
    /// - Parameter check: The finding to send through JSON.
    private func expectJSONRoundTrip(of check: HealthCheck) throws {
        let data = try JSONEncoder().encode(check)
        let decoded = try JSONDecoder().decode(HealthCheck.self, from: data)
        #expect(decoded == check)
    }

    /// Encodes `check` and reads back the keys of the JSON object it wrote.
    ///
    /// `JSONSerialization` reads the keys as they stand on the wire, so an
    /// absent key and a `null` key are two different answers here.
    ///
    /// - Parameter check: The finding to encode.
    /// - Returns: Every key the encoded object holds.
    private func encodedKeys(of check: HealthCheck) throws -> Set<String> {
        let data = try JSONEncoder().encode(check)
        let json = try JSONSerialization.jsonObject(with: data)
        let object = try #require(json as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - The defaults the protocol extension gives

    @Test func aComponentThatStatesOnlyItsNameAndCategoryGivesOneOkCheck() async {
        let checks = await MinimalComponent().runHealthChecks()
        #expect(checks.count == 1)
        #expect(checks.first?.status == .ok)
        #expect(checks.first?.name == "minimal")
        #expect(checks.first?.category == "probe")
    }

    @Test func aComponentThatStatesNoApplicabilityApplies() {
        #expect(MinimalComponent().isApplicable)
    }

    // MARK: - The three factory functions

    @Test func theOkFactoryLeavesTheFixEmpty() {
        #expect(Self.okCheck.status == .ok)
        #expect(Self.okCheck.fix == nil)
    }

    @Test func theWarningFactoryCarriesTheFixItWasGiven() {
        expectFinding(Self.warningCheck, reports: .warning, fix: "mkdir -p ~/.config/extras/transcripts")
    }

    @Test func theErrorFactoryCarriesTheFixItWasGiven() {
        expectFinding(Self.errorCheck, reports: .error, fix: "extras model download default")
    }

    // MARK: - The JSON contract the `--json` doctor output reads

    @Test func anOkCheckSurvivesAJSONRoundTrip() throws {
        try expectJSONRoundTrip(of: Self.okCheck)
    }

    @Test func anErrorCheckSurvivesAJSONRoundTrip() throws {
        try expectJSONRoundTrip(of: Self.errorCheck)
    }

    @Test func anEncodedOkCheckHoldsNoFixKey() throws {
        let keys = try encodedKeys(of: Self.okCheck)
        #expect(!keys.contains("fix"))
        #expect(keys == ["name", "status", "message", "category"])
    }

    @Test func anEncodedErrorCheckHoldsAFixKey() throws {
        let keys = try encodedKeys(of: Self.errorCheck)
        #expect(keys.contains("fix"))
    }

    @Test func healthStatusEncodesToItsWireStrings() throws {
        let data = try JSONEncoder().encode([HealthStatus.ok, .warning, .error])
        let json = try JSONSerialization.jsonObject(with: data)
        let strings = try #require(json as? [String])
        #expect(strings == ["ok", "warning", "error"])
    }
}
