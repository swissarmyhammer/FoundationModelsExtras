@testable import FoundationModelsExtras
import FoundationModels
import Testing

/// ``ToolResultAppend`` turns a tool result into a transcript segment, and
/// ``ToolResultAppendBoundary`` gives it to the session of the model call.
@Suite("ToolResultAppend: a tool result, ready for the transcript")
struct ToolResultAppendTests {
    /// The tool name that each test value uses.
    private static let toolName = "search"

    /// The arguments of a test call. The type gives its generated content.
    @Generable
    struct SearchArguments {
        /// The search text.
        let query: String
    }

    /// A result of a test call. The type gives its generated content.
    @Generable
    struct SearchResult {
        /// The number of hits.
        let hits: Int
    }

    /// Arguments that cannot give their generated content.
    private struct PlainArguments {}

    /// A result that is only a prompt, with no generated content.
    private struct PlainResult: PromptRepresentable {
        /// The text of the prompt.
        static let text = "plain result text"

        /// The prompt of the result.
        var promptRepresentation: Prompt { Prompt(Self.text) }
    }

    /// The text of `segment`, or `nil` when it is not a text segment.
    ///
    /// - Parameter segment: The segment to read.
    /// - Returns: The text content.
    private static func text(of segment: Transcript.Segment) -> String? {
        if case .text(let text) = segment { text.content } else { nil }
    }

    /// The structured segment in `segment`, or `nil` when it is not one.
    ///
    /// - Parameter segment: The segment to read.
    /// - Returns: The structured segment.
    private static func structure(of segment: Transcript.Segment) -> Transcript.StructuredSegment? {
        if case .structure(let structure) = segment { structure } else { nil }
    }

    @Test("a text result becomes a text segment, with the generated content of the arguments")
    func aTextResultIsATextSegment() throws {
        let arguments = SearchArguments(query: "swift")

        let append = ToolResultAppend(toolName: Self.toolName, arguments: arguments, text: "three hits")

        #expect(append.toolName == Self.toolName)
        #expect(append.text == "three hits")
        #expect(append.arguments == arguments.generatedContent)
        #expect(try #require(Self.text(of: append.segment)) == "three hits")
    }

    @Test("arguments that cannot give generated content become nil")
    func plainArgumentsAreNil() {
        let append = ToolResultAppend(toolName: Self.toolName, arguments: PlainArguments(), text: "done")

        #expect(append.arguments == nil)
    }

    @Test("a generable result becomes a structured segment, named for the tool, with its JSON as the text")
    func aGenerableResultIsAStructuredSegment() throws {
        let result = SearchResult(hits: 3)

        let append = ToolResultAppend(toolName: Self.toolName, arguments: PlainArguments(), result: result)

        let structure = try #require(Self.structure(of: append.segment))
        #expect(structure.schemaName == Self.toolName)
        #expect(structure.content == result.generatedContent)
        #expect(append.text == result.generatedContent.jsonString)
    }

    @Test("a result with no generated content becomes a text segment of its prompt")
    func aPromptResultIsATextSegment() throws {
        let append = ToolResultAppend(toolName: Self.toolName, arguments: PlainArguments(), result: PlainResult())

        #expect(append.text.contains(PlainResult.text))
        #expect(try #require(Self.text(of: append.segment)) == append.text)
    }

    @Test("outside a model call there is no boundary")
    func noBoundaryOutsideAModelCall() {
        #expect(ToolResultAppendBoundary.current == nil)
    }

    @Test("inside a model call the boundary gives each result to its session")
    func theBoundaryDeliversToItsSession() async {
        let delivered = Recorder<String>()
        let boundary = ToolResultAppendBoundary { result in delivered.append(result.text) }

        await ToolResultAppendBoundary.$current.withValue(boundary) {
            await ToolResultAppendBoundary.current?.deliver(
                result: ToolResultAppend(toolName: Self.toolName, arguments: PlainArguments(), text: "first"))
            await ToolResultAppendBoundary.current?.deliver(
                result: ToolResultAppend(toolName: Self.toolName, arguments: PlainArguments(), text: "second"))
        }

        #expect(delivered.values == ["first", "second"])
    }
}
