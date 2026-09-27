@testable import FoundationModelsExtras
import FoundationModels
import Testing

/// Exercises ``ToolFailureDelivery``: a failed call is a tool result that the
/// model reads, and only a cancellation throws.
@Suite("ToolFailureDelivery: a failure is the call's output, a cancellation throws")
struct ToolFailureDeliveryTests {
    /// The step that each call of this suite names.
    private static let step = "ONE"

    /// The arguments that each call of this suite sends.
    private static let arguments = StepArguments(value: step)

    /// The text the model reads for a call that failed on ``step``.
    private static let failureText = String(describing: StepFailure(step: step))

    /// The output text of a call that names `step`.
    private static func marker(for step: String) -> String {
        "MARKER-" + step
    }

    // MARK: - Test tools

    /// The arguments of each test tool.
    @Generable
    struct StepArguments {
        /// The step that the call names.
        let value: String
    }

    /// The failure of a test tool.
    struct StepFailure: Error, CustomStringConvertible, Equatable {
        /// The step that the failed call named.
        let step: String

        var description: String { ToolFailureDeliveryTests.marker(for: "FAILED-" + step) }
    }

    /// An output that is not `String` and has no generated content.
    struct PromptOutput: PromptRepresentable {
        /// The text of the output.
        let text: String

        var promptRepresentation: Prompt { Prompt(text) }
    }

    /// An output that has generated content.
    @Generable
    struct StructuredOutput: Equatable {
        /// The marker of the step.
        var marker: String
    }

    /// A `String` tool that always throws. A class, so a test can compare
    /// identity.
    final class ThrowingTool: Tool, Sendable {
        let name = "throwing"
        let description = "always fails"

        func call(arguments: StepArguments) async throws -> String {
            throw StepFailure(step: arguments.value)
        }
    }

    /// A `String` tool that always ends as cancelled.
    struct CancellingTool: Tool {
        let name = "cancelling"
        let description = "always ends as cancelled"

        func call(arguments: StepArguments) async throws -> String {
            throw CancellationError()
        }
    }

    /// A `String` tool that returns the marker of its step.
    struct MarkerTool: Tool {
        let name = "marker"
        let description = "returns the marker of its step"

        func call(arguments: StepArguments) async throws -> String {
            ToolFailureDeliveryTests.marker(for: arguments.value)
        }
    }

    /// A tool whose output is not `String`, and that always throws.
    struct ThrowingPromptTool: Tool {
        let name = "throwing-prompt"
        let description = "always fails"

        func call(arguments: StepArguments) async throws -> PromptOutput {
            throw StepFailure(step: arguments.value)
        }
    }

    /// A tool whose output is not `String`, and that returns the marker of
    /// its step.
    struct PromptTool: Tool {
        let name = "prompt"
        let description = "returns the marker of its step as a prompt"

        func call(arguments: StepArguments) async throws -> PromptOutput {
            PromptOutput(text: ToolFailureDeliveryTests.marker(for: arguments.value))
        }
    }

    /// A tool whose output has generated content.
    struct StructuredTool: Tool {
        let name = "structured"
        let description = "returns the marker of its step as a structure"

        func call(arguments: StepArguments) async throws -> StructuredOutput {
            StructuredOutput(marker: ToolFailureDeliveryTests.marker(for: arguments.value))
        }
    }

    // MARK: - The rule

    @Test("a body that returns keeps its output")
    func returnedOutputIsKept() async throws {
        let result = try await ToolCallResult<String> { Self.step }

        #expect(result.wrappedOutput == Self.step)
        #expect(result.failureText == nil)
    }

    @Test("a body that throws gives the description of its error as the failure text")
    func thrownErrorBecomesTheFailureText() async throws {
        let result = try await ToolCallResult<String> {
            throw StepFailure(step: Self.step)
        }

        #expect(result.failureText == Self.failureText)
        #expect(result.wrappedOutput == nil)
    }

    @Test("a body that throws a CancellationError throws it again")
    func cancellationIsThrownAgain() async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await ToolCallResult<String> { throw CancellationError() }
        }
    }

    // MARK: - A String-output tool

    @Test("a String-output tool that throws gives the failure text as its String output")
    func stringOutputToolFailureIsText() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: ThrowingTool())
        let tool = try #require(wrapped as? FailureDeliveringTextTool<StepArguments>)

        let output = try await tool.call(arguments: Self.arguments)

        #expect(output == Self.failureText)
    }

    @Test("a String-output tool that ends as cancelled still throws the cancellation")
    func stringOutputToolCancellationThrows() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: CancellingTool())
        let tool = try #require(wrapped as? FailureDeliveringTextTool<StepArguments>)

        await #expect(throws: CancellationError.self) {
            _ = try await tool.call(arguments: Self.arguments)
        }
    }

    @Test("a String-output tool's output passes through unchanged")
    func stringOutputPassesThrough() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: MarkerTool())
        let tool = try #require(wrapped as? FailureDeliveringTextTool<StepArguments>)

        let output = try await tool.call(arguments: Self.arguments)

        #expect(output == Self.marker(for: Self.step))
    }

    // MARK: - A tool whose output is not String

    @Test("a non-String-output tool that throws gives the failure text as its result")
    func nonStringOutputToolFailureIsTheResult() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: ThrowingPromptTool())
        let tool = try #require(wrapped as? FailureDeliveringResultTool<StepArguments, PromptOutput>)

        let result = try await tool.call(arguments: Self.arguments)

        #expect(result.failureText == Self.failureText)
    }

    @Test("a non-String-output tool's plain prompt output passes through, and stays a prompt")
    func nonStringOutputPassesThrough() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: PromptTool())
        let tool = try #require(wrapped as? FailureDeliveringResultTool<StepArguments, PromptOutput>)

        let result = try await tool.call(arguments: Self.arguments)

        #expect(result.wrappedOutput?.text == Self.marker(for: Self.step))
        // A plain prompt output stays a prompt: the SDK records it as text.
        #expect(!(result is any ConvertibleToGeneratedContent))
    }

    @Test("a structured output keeps its generated content, so the SDK still records a structure")
    func structuredOutputKeepsItsGeneratedContent() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: StructuredTool())
        let tool = try #require(wrapped as? FailureDeliveringResultTool<StepArguments, StructuredOutput>)

        let result = try await tool.call(arguments: Self.arguments)

        let expected = StructuredOutput(marker: Self.marker(for: Self.step))
        // The assignment compiles only when the conditional conformance holds.
        let convertible: any ConvertibleToGeneratedContent = result
        #expect(convertible.generatedContent == expected.generatedContent)
    }

    // MARK: - The tool beneath

    @Test("throwingTool(of:) gives the tool beneath the decorator, which still throws")
    func throwingToolIsTheToolBeneath() async throws {
        let failing = ThrowingTool()
        let beneath = ToolFailureDelivery.throwingTool(of: ToolFailureDelivery.makeWrapped(tool: failing))
        let tool = try #require(beneath as? ThrowingTool)

        #expect(tool === failing)
        await #expect(throws: StepFailure(step: Self.step)) {
            _ = try await tool.call(arguments: Self.arguments)
        }
    }

    @Test("throwingTool(of:) gives a tool with no decorator back unchanged")
    func throwingToolOfAnUndecoratedTool() throws {
        let failing = ThrowingTool()

        let tool = try #require(ToolFailureDelivery.throwingTool(of: failing) as? ThrowingTool)

        #expect(tool === failing)
    }
}

extension ToolCallResult {
    /// The output of the wrapped tool, or `nil` when the call failed.
    fileprivate var wrappedOutput: Output? {
        guard case .output(let output) = self else { return nil }
        return output
    }

    /// The failure text that the model reads, or `nil` when the call
    /// returned an output.
    fileprivate var failureText: String? {
        guard case .failure(let text) = self else { return nil }
        return text
    }
}
