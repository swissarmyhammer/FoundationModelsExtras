import FoundationModels
@testable import FoundationModelsExtras
import TelemetryTestSupport
import Testing
import Tracing

/// Rule 4 and rule 5 of the OpenTelemetry design of 2026-09-28: no span, log
/// record or metric of a tool call carries the tool arguments or the tool
/// output. Each test runs one tool call through one of the three runners with
/// a distinctive argument and a distinctive output, and forbids both strings
/// in the capture of ``TelemetryCapture``. One test gives both strings to the
/// description of an error that the tool throws, because the span of the call
/// sees that error.
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

    /// The `error.type` of ``ContentError/carrying(_:)``: the type name and
    /// the case name, never the payload.
    private static let contentErrorType = "\(String(reflecting: ContentError.self)).carrying"

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

    @Test("a run-to-completion call of a tool that throws an error with content carries no content in its telemetry")
    func aThrowingCallCarriesNoContent() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: ContentThrowingTool())

        let context = try await TelemetryCapture.run(forbidding: Self.forbidden) { context in
            await #expect(throws: ContentError.self) {
                try await harness.mounted.call(arguments: MountArguments(value: Self.argument))
            }
            return context
        }

        Self.expectOneCall(in: context)
        let span = try #require(context.spans.first)
        #expect(span.status == SpanStatus(code: .error))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.errorType) == .string(Self.contentErrorType))
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

/// The error of ``ContentThrowingTool``. Its description holds the content
/// of the call.
private enum ContentError: Error {
    /// A failure that carries the output and the argument of the call.
    case carrying(String)
}

/// Throws an error whose description holds the distinctive output of the
/// suite and the argument of the call.
private struct ContentThrowingTool: Tool {
    let name = "content_throwing_tool"
    let description = "throws an error that holds content"

    func call(arguments: MountArguments) async throws -> String {
        throw ContentError.carrying("\(ExtrasContentSafetyTests.output) for \(arguments.value)")
    }
}
