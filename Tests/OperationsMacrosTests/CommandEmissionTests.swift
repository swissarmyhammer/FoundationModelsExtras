import ArgumentParser
import FoundationModels
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import Operations
@testable import OperationsMacros

/// `MacroSpec` for `@Operation`, declaring the `OperationDefinition`/
/// `HasCLICommand` conformances the real `@attached(extension,
/// conformances: ...)` declaration in `Operations.swift` grants it.
///
/// Shared with `OperationMacroTests`; duplicated here (rather than
/// imported) since `assertMacroExpansion` fixtures are conventionally
/// self-contained per test file.
private let operationMacroSpecs: [String: MacroSpec] = [
    "Operation": MacroSpec(type: OperationMacro.self, conformances: ["OperationDefinition", "HasCLICommand"])
]

@Suite struct CommandEmissionExpansionTests {

    // MARK: - Flag / repeatable-option / optional-option / required-option mapping

    @Test func generatedCommandMapsEachFieldKindToItsArgumentParserWrapper() {
        assertMacroExpansion(
            """
            @Operation(verb: "tag", noun: "note", description: "Tag a note")
            struct TagNote {
                @Guide(description: "The note title")
                var title: String

                @Guide(description: "A note about the tagging")
                var note: String?

                @Guide(description: "Tags to attach")
                var labels: [String]

                @Guide(description: "Whether to notify watchers")
                var notify: Bool
            }
            """,
            expandedSource: """
                struct TagNote {
                    @Guide(description: "The note title")
                    var title: String

                    @Guide(description: "A note about the tagging")
                    var note: String?

                    @Guide(description: "Tags to attach")
                    var labels: [String]

                    @Guide(description: "Whether to notify watchers")
                    var notify: Bool
                }

                extension TagNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "tag"
                    static let noun: String = "note"
                    static let operationDescription: String = "Tag a note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
                        ParamMeta(name: "note", type: .string, required: false, description: "A note about the tagging"),
                        ParamMeta(name: "labels", type: .array(of: .string), required: true, description: "Tags to attach"),
                        ParamMeta(name: "notify", type: .boolean, required: true, description: "Whether to notify watchers"),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "tag", abstract: "Tag a note")

                        @Option(help: "The note title")
                        var title: String

                        @Option(help: "A note about the tagging")
                        var note: String?

                        @Option(help: "Tags to attach")
                        var labels: [String] = []

                        @Flag(help: "Whether to notify watchers")
                        var notify: Bool = false

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", TagNote.opString)]
                            payload.append(("title", title))
                            if let note {
                                payload.append(("note", note))
                            }
                            payload.append(("labels", labels))
                            payload.append(("notify", notify))
                            return GeneratedContent(properties: payload, uniquingKeysWith: { _, new in
                                    new
                                })
                        }

                        mutating func run() async throws {
                            print(operationPayload().jsonString)
                        }
                    }

                    typealias CLICommand = Command
                }
                """,
            macroSpecs: operationMacroSpecs
        )
    }

    // MARK: - `@OperationParam(short:)` on the generated `Command`

    @Test func operationParamShortProducesCombinedLongAndShortNameSpecification() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                @Guide(description: "The note title")
                @OperationParam(short: "t")
                var title: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    @Guide(description: "The note title")
                    @OperationParam(short: "t")
                    var title: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "title", type: .string, required: true, description: "The note title", short: "t"),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")

                        @Option(name: [.long, .customShort("t")], help: "The note title")
                        var title: String

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]
                            payload.append(("title", title))
                            return GeneratedContent(properties: payload, uniquingKeysWith: { _, new in
                                    new
                                })
                        }

                        mutating func run() async throws {
                            print(operationPayload().jsonString)
                        }
                    }

                    typealias CLICommand = Command
                }
                """,
            macroSpecs: operationMacroSpecs
        )
    }

    // MARK: - Nested-array field: `ParamMeta` entry, but no `Command` field

    /// A nested array (`[[String]]`) is a valid `ParamMeta` type
    /// (`primitiveParamTypeExprText` recurses through `[T]` unconditionally)
    /// but has no `ArgumentParser` representation (`commandFieldKind` only
    /// handles one level of array, since `ArgumentParser`'s repeatable
    /// `@Option` needs an `ExpressibleByArgument`-conforming element type,
    /// and `[String]` doesn't conform). Such a property must still appear in
    /// `parameterMetadata`, but is silently omitted from `Command` — no
    /// diagnostic, no `@Option`/`@Flag` line, no payload-building statement.
    @Test func nestedArrayFieldGetsParamMetaEntryButNoCommandField() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                @Guide(description: "The note title")
                var title: String

                @Guide(description: "Groups of related tags")
                var tagGroups: [[String]]
            }
            """,
            expandedSource: """
                struct AddNote {
                    @Guide(description: "The note title")
                    var title: String

                    @Guide(description: "Groups of related tags")
                    var tagGroups: [[String]]
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
                        ParamMeta(name: "tagGroups", type: .array(of: .array(of: .string)), required: true, description: "Groups of related tags"),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")

                        @Option(help: "The note title")
                        var title: String

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]
                            payload.append(("title", title))
                            return GeneratedContent(properties: payload, uniquingKeysWith: { _, new in
                                    new
                                })
                        }

                        mutating func run() async throws {
                            print(operationPayload().jsonString)
                        }
                    }

                    typealias CLICommand = Command
                }
                """,
            macroSpecs: operationMacroSpecs
        )
    }
}

// MARK: - Compile-and-parse fixture

/// Context passed to `AddNoteCommandFixture.execute(in:)`.
///
/// Unused by
/// `CommandCompileAndParseTests`, which only exercises payload
/// construction, but required by `OperationDefinition`.
private struct CommandFixtureContext: Sendable {}

/// JSON-encodable result produced by `AddNoteCommandFixture.execute(in:)`.
private struct AddNoteCommandFixtureOutput: Encodable, Sendable {}

/// A real `@Generable @Operation(...)` struct — proving, under the actual
/// Swift compiler (not the `assertMacroExpansion` simulation harness), that
/// the generated `Command` parses real command-line arguments and its
/// `operationPayload()` matches the shape the model path sends.
///
/// Mirrors plan.md's "Declaring an operation" `AddNote` example's field set
/// (`title`, `body`, `tags`), plus a `pinned: Bool` field so all four
/// `CommandFieldKind` mappings (required option, optional option, repeatable
/// option, flag) are exercised through a real compile, not just
/// `assertMacroExpansion` — and a required `scores: [Int]` array, since a
/// repeatable option always defaults to `[]` regardless of its
/// `ParamMeta.required`, distinguishing the required-array round trip from
/// the optional-array one (`tags`).
@Generable
@Operation(verb: "add", noun: "note", description: "Create a new note")
private struct AddNoteCommandFixture {
    @Guide(description: "The note title")
    var title: String

    @Guide(description: "Markdown body of the note")
    var body: String?

    @Guide(description: "Tags to attach")
    var tags: [String]?

    @Guide(description: "Whether the note is pinned")
    var pinned: Bool

    @Guide(description: "Revision scores")
    var scores: [Int]
}

extension AddNoteCommandFixture {
    func execute(in context: CommandFixtureContext) async throws -> AddNoteCommandFixtureOutput {
        AddNoteCommandFixtureOutput()
    }
}

@Suite struct CommandCompileAndParseTests {

    @Test func parsedCommandPayloadContainsOpAndSuppliedRequiredField() throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi"])
        let payload = command.operationPayload()

        #expect(try payload.value(String.self, forProperty: "op") == AddNoteCommandFixture.opString)
        #expect(try payload.value(String.self, forProperty: "title") == "Hi")
    }

    @Test func parsedCommandPayloadOmitsAnUnsuppliedOptionalArrayField() throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi"])
        let payload = command.operationPayload()

        #expect(try payload.value([String]?.self, forProperty: "tags") == nil)
    }

    @Test func parsedCommandPayloadOmitsAnUnsuppliedOptionalScalarField() throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi"])
        let payload = command.operationPayload()

        #expect(try payload.value(String?.self, forProperty: "body") == nil)
    }

    @Test func parsedCommandPayloadIncludesASuppliedOptionalScalarField() throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi", "--body", "Groceries list"])
        let payload = command.operationPayload()

        #expect(try payload.value(String.self, forProperty: "body") == "Groceries list")
    }

    @Test func parsedCommandPayloadIncludesRepeatedOptionValuesAsAnArray() throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi", "--tags", "a", "--tags", "b"])
        let payload = command.operationPayload()

        #expect(try payload.value([String].self, forProperty: "tags") == ["a", "b"])
    }

    @Test func parsedCommandPayloadDefaultsAnUnsuppliedFlagToFalse() throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi"])
        let payload = command.operationPayload()

        #expect(try payload.value(Bool.self, forProperty: "pinned") == false)
    }

    @Test func parsedCommandPayloadReflectsASuppliedFlagAsTrue() throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi", "--pinned"])
        let payload = command.operationPayload()

        #expect(try payload.value(Bool.self, forProperty: "pinned") == true)
    }

    @Test func parsedCommandPayloadMatchesTheShapeAnyOperationRunDecodes() async throws {
        let command = try AddNoteCommandFixture.Command.parse([
            "--title", "Hi", "--body", "Groceries list", "--tags", "a", "--tags", "b", "--pinned", "--scores", "1",
            "--scores", "2",
        ])
        let payload = command.operationPayload()

        // The model path sends `AnyOperation.run` a payload built the same
        // way (`GeneratedContent(properties:)`) but without the `op`
        // discriminator, since `OperationTool.call` (a later task) will
        // strip it before typed construction. Decoding the CLI payload
        // through the identical `AddNoteCommandFixture(_:)` initializer
        // proves the two payload shapes converge on the same typed
        // operation — across every field kind (required option, optional
        // option, repeatable option, flag), not just a subset of them.
        let decoded = try AddNoteCommandFixture(payload)
        #expect(decoded.title == "Hi")
        #expect(decoded.body == "Groceries list")
        #expect(decoded.tags == ["a", "b"])
        #expect(decoded.pinned == true)
        #expect(decoded.scores == [1, 2])
    }

    @Test func parsedCommandPayloadMatchesTheShapeAnyOperationRunDecodesWithUnsuppliedOptionalsAndFlag() async throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi"])
        let payload = command.operationPayload()

        // The inverse of the above: unsupplied optional/flag fields must
        // also decode correctly (to `nil`/`false`), not just supplied ones
        // — and the unsupplied required array field must decode to `[]`.
        let decoded = try AddNoteCommandFixture(payload)
        #expect(decoded.title == "Hi")
        #expect(decoded.body == nil)
        #expect(decoded.tags == nil)
        #expect(decoded.pinned == false)
        #expect(decoded.scores == [])
    }

    @Test func parsedCommandPayloadIncludesAnUnsuppliedRequiredArrayFieldAsEmpty() throws {
        // Unlike an optional array field, a required array field is always
        // present in the payload (see `payloadAssignmentText`'s
        // `.repeatableOption` case) — sent as `[]` rather than omitted,
        // since omitting it would leave the payload missing the key
        // entirely, which `Generable`'s synthesized initializer throws
        // decoding for a non-optional property.
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi"])
        let payload = command.operationPayload()

        #expect(try payload.value([Int].self, forProperty: "scores") == [])
    }

    @Test func parsedCommandPayloadWithAnUnsuppliedRequiredArrayFieldStillDecodesToAnEmptyArray() async throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi"])
        let payload = command.operationPayload()

        // Completes the round trip the previous test only builds the
        // payload for: `AddNoteCommandFixture`'s `@Generable`-synthesized
        // initializer decodes the payload's empty `scores` array back to an
        // empty array.
        let decoded = try AddNoteCommandFixture(payload)
        #expect(decoded.scores == [])
    }

    @Test func parsedCommandPayloadIncludesASuppliedRequiredArrayField() async throws {
        let command = try AddNoteCommandFixture.Command.parse(["--title", "Hi", "--scores", "1", "--scores", "2"])
        let payload = command.operationPayload()

        #expect(try payload.value([Int].self, forProperty: "scores") == [1, 2])
        let decoded = try AddNoteCommandFixture(payload)
        #expect(decoded.scores == [1, 2])
    }
}
