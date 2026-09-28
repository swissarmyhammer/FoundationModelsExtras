import FoundationModels
@testable import FoundationModelsExtras
import TelemetryTestSupport
import Testing

/// Rule 4 and rule 5 of the OpenTelemetry design of 2026-09-28: no span, log
/// record or metric of a tool call carries the tool arguments or the tool
/// output. Each test runs one tool call through one of the three runners with
/// a distinctive argument and a distinctive output, and forbids both strings
/// in the capture of ``TelemetryCapture``.
@Suite("ExtrasContentSafety: no tool argument and no tool output in the telemetry of a tool call")
struct ExtrasContentSafetyTests {
    /// The shared fixtures of the runner suites.
    private typealias Fixtures = MountFixtures

    /// The argument of each call.
    private static let argument = "tool-argument-5e2c"

    /// The output of each tool.
    fileprivate static let output = "tool-output-9a61"

    /// The strings that no place of the telemetry may carry.
    private static let forbidden = [argument, output]

    /// The count of spans, and of "enter" log records, of one tool call.
    private static let recordsOfOneCall = 1

    @Test("a run-to-completion call carries no content in its telemetry")
    func aRunToCompletionCallCarriesNoContent() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: DistinctOutputTool())

        let context = try await TelemetryCapture.run(forbidding: Self.forbidden) { context in
            let value = try await harness.mounted.call(arguments: MountArguments(value: Self.argument))
            #expect(value.contains(Self.output))
            return context
        }

        Self.expectOneCall(in: context)
    }

    @Test("a background call carries no content in its telemetry")
    func aBackgroundCallCarriesNoContent() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: DistinctOutputTool())

        let context = try await TelemetryCapture.run(forbidding: Self.forbidden) { context in
            _ = try await harness.mounted.call(arguments: MountArguments(value: Self.argument))
            return context
        }

        Self.expectOneCall(in: context)
    }

    @Test("a bound call of a tool whose output is not String carries no content in its telemetry")
    func aBoundCallCarriesNoContent() async throws {
        let bound = ContextBindingTool(
            wrapping: DistinctNonStringOutputTool(),
            site: Fixtures.site(runPlane: RunPlane(), sink: Fixtures.RecordingSink())
        )

        let context = try await TelemetryCapture.run(forbidding: Self.forbidden) { context in
            let value = try await bound.call(arguments: MountArguments(value: Self.argument))
            #expect(value.text.contains(Self.output))
            return context
        }

        Self.expectOneCall(in: context)
    }

    /// Expects that the capture measured one tool call. A capture that
    /// recorded nothing passes the content check with no issue, thus each
    /// test states what the capture measured.
    ///
    /// - Parameter context: The capture of the call.
    private static func expectOneCall(in context: TelemetryCapture.Context) {
        #expect(context.spans.count == recordsOfOneCall)
        #expect(context.logRecords.count == recordsOfOneCall)
        #expect(context.metricRecords.map(\.label).sorted() == [
            ExtrasTelemetry.MetricName.toolCalls,
            ExtrasTelemetry.MetricName.toolDuration,
        ])
    }
}

/// Returns the distinctive output of the suite, with the argument of the
/// call.
private struct DistinctOutputTool: Tool {
    let name = "distinct_output_tool"
    let description = "returns a distinctive output"

    func call(arguments: MountArguments) async throws -> String {
        "\(ExtrasContentSafetyTests.output) for \(arguments.value)"
    }
}

/// Returns the distinctive output of the suite, with the argument of the
/// call, as an output that is not `String`.
private struct DistinctNonStringOutputTool: Tool {
    let name = "distinct_non_string_output_tool"
    let description = "returns a distinctive output that is not String"

    func call(arguments: MountArguments) async throws -> NonStringToolOutput {
        NonStringToolOutput(text: "\(ExtrasContentSafetyTests.output) for \(arguments.value)")
    }
}
