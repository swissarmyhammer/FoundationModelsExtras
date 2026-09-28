@testable import FoundationModelsExtras
import Testing

/// ``ExtrasTelemetry`` gives the logger and the tool-call metrics of the core
/// target, with the module name as the prefix of each name.
@Suite("ExtrasTelemetry: the logger and the tool-call metrics of the core target")
struct ExtrasTelemetryTests {
    /// The tool name that each metric test uses.
    private static let toolName = "search"

    /// The outcome that each metric test uses.
    private static let outcome = OperationOutcome.timedOut

    /// The dimensions that each tool-call metric must carry, in order.
    private static let expectedDimensions = [
        ("tool.name", toolName),
        ("tool.outcome", outcome.rawValue),
    ]

    @Test("the logger has the module name as its label")
    func theLoggerHasTheModuleLabel() {
        #expect(ExtrasTelemetry.logLabel == "FoundationModelsExtras")
        #expect(ExtrasTelemetry.makeLogger().label == ExtrasTelemetry.logLabel)
    }

    @Test("the tool-call counter has its name and the tool name and outcome as its only dimensions")
    func theToolCallCounterHasItsNameAndDimensions() {
        let counter = ExtrasTelemetry.makeToolCallCounter(toolName: Self.toolName, outcome: Self.outcome)

        #expect(counter.label == "FoundationModelsExtras.tool.calls")
        #expect(counter.label == ExtrasTelemetry.MetricName.toolCalls)
        #expect(counter.dimensions.elementsEqual(Self.expectedDimensions, by: ==))
    }

    @Test("the tool-duration timer has its name and the tool name and outcome as its only dimensions")
    func theToolDurationTimerHasItsNameAndDimensions() {
        let timer = ExtrasTelemetry.makeToolDurationTimer(toolName: Self.toolName, outcome: Self.outcome)

        #expect(timer.label == "FoundationModelsExtras.tool.duration")
        #expect(timer.label == ExtrasTelemetry.MetricName.toolDuration)
        #expect(timer.dimensions.elementsEqual(Self.expectedDimensions, by: ==))
    }
}
