import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import OperationsMacros

/// `MacroSpec` for `@Operation`, declaring the `OperationDefinition`/
/// `HasCLICommand` conformances the real `@attached(extension,
/// conformances: ...)` declaration in `Operations.swift` grants it.
private let operationMacroSpecs: [String: MacroSpec] = [
    "Operation": MacroSpec(type: OperationMacro.self, conformances: ["OperationDefinition", "HasCLICommand"])
]

@Suite struct OperationMacroTests {

    // MARK: - Simple op

    @Test func simpleOpSynthesizesOperationDefinitionConformance() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                @Guide(description: "The note title")
                var title: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    @Guide(description: "The note title")
                    var title: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
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

    // MARK: - Optional / array fields

    @Test func optionalAndArrayFieldsMapToNotRequiredAndArrayParamType() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                @Guide(description: "The note title")
                var title: String

                @Guide(description: "Markdown body of the note")
                var body: String?

                @Guide(description: "Tags to attach")
                var tags: [String]?
            }
            """,
            expandedSource: """
                struct AddNote {
                    @Guide(description: "The note title")
                    var title: String

                    @Guide(description: "Markdown body of the note")
                    var body: String?

                    @Guide(description: "Tags to attach")
                    var tags: [String]?
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
                        ParamMeta(name: "body", type: .string, required: false, description: "Markdown body of the note"),
                        ParamMeta(name: "tags", type: .array(of: .string), required: false, description: "Tags to attach"),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")

                        @Option(help: "The note title")
                        var title: String

                        @Option(help: "Markdown body of the note")
                        var body: String?

                        @Option(help: "Tags to attach")
                        var tags: [String] = []

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]
                            payload.append(("title", title))
                            if let body {
                                payload.append(("body", body))
                            }
                            if !tags.isEmpty {
                                payload.append(("tags", tags))
                            }
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

    // MARK: - Int / Double / Bool / required-array field types

    @Test func numericBooleanAndRequiredArrayFieldsMapToTheirParamTypes() {
        assertMacroExpansion(
            """
            @Operation(verb: "update", noun: "note", description: "Update a note")
            struct UpdateNote {
                @Guide(description: "How many times the note was viewed")
                var viewCount: Int

                @Guide(description: "The note's average rating")
                var rating: Double?

                @Guide(description: "Whether the note is pinned")
                var pinned: Bool

                @Guide(description: "Scores for each revision")
                var scores: [Int]
            }
            """,
            expandedSource: """
                struct UpdateNote {
                    @Guide(description: "How many times the note was viewed")
                    var viewCount: Int

                    @Guide(description: "The note's average rating")
                    var rating: Double?

                    @Guide(description: "Whether the note is pinned")
                    var pinned: Bool

                    @Guide(description: "Scores for each revision")
                    var scores: [Int]
                }

                extension UpdateNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "update"
                    static let noun: String = "note"
                    static let operationDescription: String = "Update a note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "viewCount", type: .integer, required: true, description: "How many times the note was viewed"),
                        ParamMeta(name: "rating", type: .number, required: false, description: "The note's average rating"),
                        ParamMeta(name: "pinned", type: .boolean, required: true, description: "Whether the note is pinned"),
                        ParamMeta(name: "scores", type: .array(of: .integer), required: true, description: "Scores for each revision"),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a note")

                        @Option(help: "How many times the note was viewed")
                        var viewCount: Int

                        @Option(help: "The note's average rating")
                        var rating: Double?

                        @Flag(help: "Whether the note is pinned")
                        var pinned: Bool = false

                        @Option(help: "Scores for each revision")
                        var scores: [Int] = []

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", UpdateNote.opString)]
                            payload.append(("viewCount", viewCount))
                            if let rating {
                                payload.append(("rating", rating))
                            }
                            payload.append(("pinned", pinned))
                            payload.append(("scores", scores))
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

    // MARK: - Unit struct (no fields)

    @Test func unitStructProducesEmptyParameterMetadata() {
        assertMacroExpansion(
            """
            @Operation(verb: "list", noun: "notes", description: "List every note")
            struct ListNotes {
            }
            """,
            expandedSource: """
                struct ListNotes {
                }

                extension ListNotes: OperationDefinition, HasCLICommand {
                    static let verb: String = "list"
                    static let noun: String = "notes"
                    static let operationDescription: String = "List every note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "list", abstract: "List every note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", ListNotes.opString)]

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

    // MARK: - Explicit non-`public` access-level modifier

    /// An explicit non-`public` access modifier — as opposed to omitting an
    /// access modifier entirely, which never even invokes the predicate,
    /// since `Array.first(where:)` short-circuits on an empty
    /// `modifiers` collection — exercises
    /// `DeclModifierSyntax.isNeededAccessLevelModifier`'s `default: return
    /// false` branch. The generated extension's members still carry no
    /// explicit access modifier, identical to the implicit-internal case.
    @Test func explicitInternalAccessModifierProducesNoAccessModifierPrefix() {
        assertMacroExpansion(
            """
            @Operation(verb: "list", noun: "notes", description: "List every note")
            internal struct ListNotes {
            }
            """,
            expandedSource: """
                internal struct ListNotes {
                }

                extension ListNotes: OperationDefinition, HasCLICommand {
                    static let verb: String = "list"
                    static let noun: String = "notes"
                    static let operationDescription: String = "List every note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "list", abstract: "List every note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", ListNotes.opString)]

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

    // MARK: - `@OperationParam` short/aliases

    @Test func operationParamSuppliesShortAndAliases() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                @Guide(description: "The note title")
                @OperationParam(short: "t", aliases: ["name"])
                var title: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    @Guide(description: "The note title")
                    @OperationParam(short: "t", aliases: ["name"])
                    var title: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "title", type: .string, required: true, description: "The note title", short: "t", aliases: ["name"]),
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

    // MARK: - `@Guide` with constraint arguments (`.anyOf`)

    @Test func guideAnyOfConstraintSuppliesAllowedValues() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                @Guide(description: "The note priority", .anyOf(["low", "medium", "high"]))
                var priority: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    @Guide(description: "The note priority", .anyOf(["low", "medium", "high"]))
                    var priority: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "priority", type: .string, required: true, description: "The note priority", allowedValues: ["low", "medium", "high"]),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")

                        @Option(help: "The note priority")
                        var priority: String

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]
                            payload.append(("priority", priority))
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

    // MARK: - `@Guide` with a non-`anyOf` constraint argument

    /// A `@Guide` constraint argument that isn't a recognized
    /// `.anyOf([...])` call (here `.range(...)`) doesn't satisfy
    /// `anyOfAllowedValues(from:)`'s recognized shape, so `allowedValues` is
    /// correctly omitted from the generated `ParamMeta(...)` rather than
    /// mis-parsed as an empty or partial array.
    @Test func guideRangeConstraintOmitsAllowedValues() {
        assertMacroExpansion(
            """
            @Operation(verb: "update", noun: "note", description: "Update a note")
            struct UpdateNote {
                @Guide(description: "Number of reviews", .range(1...10))
                var reviewCount: Int
            }
            """,
            expandedSource: """
                struct UpdateNote {
                    @Guide(description: "Number of reviews", .range(1...10))
                    var reviewCount: Int
                }

                extension UpdateNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "update"
                    static let noun: String = "note"
                    static let operationDescription: String = "Update a note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "reviewCount", type: .integer, required: true, description: "Number of reviews"),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a note")

                        @Option(help: "Number of reviews")
                        var reviewCount: Int

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", UpdateNote.opString)]
                            payload.append(("reviewCount", reviewCount))
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

    // MARK: - `@OperationParam` explicit empty `allowedValues`

    /// An explicit `allowedValues: []` is a closed set with zero members —
    /// distinct from omitting `allowedValues` entirely (which leaves the
    /// constraint unset). The generated `ParamMeta(...)` call must preserve
    /// that distinction by still emitting `allowedValues: []`.
    @Test func explicitEmptyAllowedValuesIsPreservedRatherThanOmitted() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                @Guide(description: "The note priority")
                @OperationParam(allowedValues: [])
                var priority: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    @Guide(description: "The note priority")
                    @OperationParam(allowedValues: [])
                    var priority: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "priority", type: .string, required: true, description: "The note priority", allowedValues: []),
                    ]

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")

                        @Option(help: "The note priority")
                        var priority: String

                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            var payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]
                            payload.append(("priority", priority))
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

    // MARK: - Doc-comment-trivia description fallback

    @Test func docCommentTriviaSuppliesDescriptionWhenNoGuideIsPresent() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                /// The note title
                var title: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    /// The note title
                    var title: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = [
                        ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
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

    // MARK: - Reserved `op` diagnostic

    @Test func reservedOpParameterNameProducesDiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                var op: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    var op: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]

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
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "parameter 'op' is reserved: it normalizes to 'op', which collides with the fused-tool discriminator field",
                    line: 3,
                    column: 9
                )
            ],
            macroSpecs: operationMacroSpecs
        )
    }

    @Test func nameThatNormalizesToOpProducesDiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                var _Op: String
            }
            """,
            expandedSource: """
                struct AddNote {
                    var _Op: String
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]

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
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "parameter '_Op' is reserved: it normalizes to 'op', which collides with the fused-tool discriminator field",
                    line: 3,
                    column: 9
                )
            ],
            macroSpecs: operationMacroSpecs
        )
    }

    // MARK: - Unsupported-type diagnostic

    @Test func unsupportedFieldTypeProducesDiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                var createdAt: Date
            }
            """,
            expandedSource: """
                struct AddNote {
                    var createdAt: Date
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]

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
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "parameter 'createdAt' has an unsupported type; '@Operation' supports String, Int, Double, Float, Bool, Array of those, and Optional wrapping any of those",
                    line: 3,
                    column: 20
                )
            ],
            macroSpecs: operationMacroSpecs
        )
    }

    /// A structurally unusual type — here a dictionary type — rather than
    /// merely an unrecognized identifier type (as `Date` above is), so
    /// neither `TypeSyntax.as(ArrayTypeSyntax.self)` nor
    /// `TypeSyntax.as(IdentifierTypeSyntax.self)` matches and
    /// `primitiveParamTypeExprText(_:)` falls through its final `return
    /// nil`.
    @Test func structurallyUnsupportedDictionaryTypeProducesDiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            struct AddNote {
                var tags: [String: Int]
            }
            """,
            expandedSource: """
                struct AddNote {
                    var tags: [String: Int]
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]

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
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "parameter 'tags' has an unsupported type; '@Operation' supports String, Int, Double, Float, Bool, Array of those, and Optional wrapping any of those",
                    line: 3,
                    column: 15
                )
            ],
            macroSpecs: operationMacroSpecs
        )
    }

    // MARK: - Missing verb / noun diagnostics

    @Test func emptyVerbProducesDiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "", noun: "note", description: "Create a new note")
            struct AddNote {
            }
            """,
            expandedSource: """
                struct AddNote {
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = ""
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "", abstract: "Create a new note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]

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
            diagnostics: [
                DiagnosticSpec(
                    message: "'@Operation' requires a non-empty 'verb' string literal argument",
                    line: 1,
                    column: 18
                )
            ],
            macroSpecs: operationMacroSpecs
        )
    }

    @Test func emptyNounProducesDiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "", description: "Create a new note")
            struct AddNote {
            }
            """,
            expandedSource: """
                struct AddNote {
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "add"
                    static let noun: String = ""
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a new note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]

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
            diagnostics: [
                DiagnosticSpec(
                    message: "'@Operation' requires a non-empty 'noun' string literal argument",
                    line: 1,
                    column: 31
                )
            ],
            macroSpecs: operationMacroSpecs
        )
    }

    // MARK: - Non-literal `verb` argument

    /// A `verb` argument that isn't a plain string literal (e.g. an
    /// interpolated string) doesn't satisfy
    /// `ExprSyntax.plainStringLiteralValue`, so
    /// `validateNonEmptyStringArgument` can't classify it as empty and emits
    /// no diagnostic — the argument's raw source text is instead embedded
    /// verbatim into the generated `verb` static and `commandName`.
    @Test func nonLiteralVerbArgumentIsEmbeddedVerbatimWithoutADiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "\\(dynamicVerb)", noun: "note", description: "Create a new note")
            struct AddNote {
            }
            """,
            expandedSource: """
                struct AddNote {
                }

                extension AddNote: OperationDefinition, HasCLICommand {
                    static let verb: String = "\\(dynamicVerb)"
                    static let noun: String = "note"
                    static let operationDescription: String = "Create a new note"
                    static let parameterMetadata: [ParamMeta] = []

                    struct Command: AsyncParsableCommand, OperationCommand {
                        static let configuration = CommandConfiguration(commandName: "\\(dynamicVerb)", abstract: "Create a new note")



                        init() {
                        }

                        /// The canonical `op` + fields payload built from this command's
                        /// parsed values, in the identical shape `AnyOperation.run`
                        /// expects and the model path sends.
                        func operationPayload() -> GeneratedContent {
                            let payload: [(String, any ConvertibleToGeneratedContent)] = [("op", AddNote.opString)]

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

    // MARK: - Non-struct diagnostic

    @Test func nonStructDeclarationProducesDiagnostic() {
        assertMacroExpansion(
            """
            @Operation(verb: "add", noun: "note", description: "Create a new note")
            enum AddNote {
            }
            """,
            expandedSource: """
                enum AddNote {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'@Operation' can only be applied to a struct",
                    line: 1,
                    column: 1
                )
            ],
            macroSpecs: operationMacroSpecs
        )
    }
}
