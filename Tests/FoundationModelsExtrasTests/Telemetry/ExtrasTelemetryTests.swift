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

    @Test("the span name has the module name as its prefix, and each key has its dotted name")
    func theVocabularyHasItsNames() {
        #expect(ExtrasTelemetry.SpanName.tool == "FoundationModelsExtras.tool")
        #expect(ExtrasTelemetry.AttributeKey.toolName == "tool.name")
        #expect(ExtrasTelemetry.AttributeKey.sessionID == "session.id")
        #expect(ExtrasTelemetry.AttributeKey.runKind == "tool.run_kind")
        #expect(ExtrasTelemetry.AttributeKey.outcome == "tool.outcome")
        #expect(ExtrasTelemetry.AttributeKey.errorType == "error.type")
        #expect(ExtrasTelemetry.LogMetadataKey.toolName == ExtrasTelemetry.AttributeKey.toolName)
        #expect(ExtrasTelemetry.LogMetadataKey.sessionID == ExtrasTelemetry.AttributeKey.sessionID)
    }

    /// A payload that a test error carries. It is not a word of the error
    /// type, thus an `error.type` value that holds it shows a leak.
    private static let payload = "/secret/path"

    /// An enum error with one case that has a payload and one case that has
    /// no payload.
    private enum LoadError: Error {
        case missing(String)
        case empty
    }

    /// A struct error that holds a payload.
    private struct ParseError: Error {
        let path: String
    }

    /// An enum error with a custom mirror that puts its payload in the label
    /// of its child, where the case name usually is.
    private enum CustomError: Error, CustomReflectable {
        case missing(String)

        var customMirror: Mirror {
            switch self {
            case .missing(let path):
                Mirror(self, children: [(label: path, value: path)], displayStyle: .enum)
            }
        }
    }

    @Test("the error type of an enum case with a payload is the type name, then the case name")
    func theErrorTypeOfAPayloadCaseHasTheCaseName() {
        let error = LoadError.missing(Self.payload)

        #expect(ExtrasTelemetry.errorType(of: error) == String(reflecting: LoadError.self) + ".missing")
    }

    @Test("the error type of an enum case with no payload is the type name only")
    func theErrorTypeOfACaseWithNoPayloadIsTheTypeName() {
        #expect(ExtrasTelemetry.errorType(of: LoadError.empty) == String(reflecting: LoadError.self))
    }

    @Test("the error type of a struct error is the type name only")
    func theErrorTypeOfAStructIsTheTypeName() {
        let error = ParseError(path: Self.payload)

        #expect(ExtrasTelemetry.errorType(of: error) == String(reflecting: ParseError.self))
    }

    @Test("the error type of a custom-reflectable enum error is the type name only, never the label of its mirror")
    func theErrorTypeOfACustomReflectableErrorIsTheTypeName() {
        let error = CustomError.missing(Self.payload)

        #expect(ExtrasTelemetry.errorType(of: error) == String(reflecting: CustomError.self))
    }
}
