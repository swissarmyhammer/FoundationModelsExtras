import Darwin
import Foundation
import FoundationModels
import Testing

@testable import Operations
@testable import OperationsCLI

// MARK: - Fixtures

/// Shared `Context` for the macro-generated "notes" tool fixtures below.
private struct NotesFixtureContext: Sendable {}

/// JSON-encodable result produced by `AddNoteCLIFixture.execute(in:)`.
private struct AddNoteCLIOutput: Encodable, Sendable, Equatable {
    let title: String
    let tags: [String]
    let pinned: Bool
    let urgent: Bool
    let priority: Int?
}

/// `add note` fixture: a required `title` (short `-t`), an optional `tags`
/// array (repeated-option coverage), two boolean flags with short names
/// (`-p`/`-u`, combined-short-flag coverage), and an optional `priority`
/// (bad-int-error coverage).
@Generable
@Operation(verb: "add", noun: "note", description: "Add a note")
private struct AddNoteCLIFixture {
    @Guide(description: "The note title")
    @OperationParam(short: "t")
    var title: String

    @Guide(description: "Tags to attach")
    var tags: [String]?

    @Guide(description: "Whether the note is pinned")
    @OperationParam(short: "p")
    var pinned: Bool

    @Guide(description: "Whether the note is urgent")
    @OperationParam(short: "u")
    var urgent: Bool

    @Guide(description: "The note's priority")
    var priority: Int?
}

extension AddNoteCLIFixture {
    func execute(in context: NotesFixtureContext) async throws -> AddNoteCLIOutput {
        AddNoteCLIOutput(title: title, tags: tags ?? [], pinned: pinned, urgent: urgent, priority: priority)
    }
}

/// JSON-encodable result produced by `DeleteNoteCLIFixture.execute(in:)`.
private struct DeleteNoteCLIOutput: Encodable, Sendable, Equatable {
    let id: String
}

/// `delete note` fixture: a second macro-generated verb under the "note"
/// noun, so `NounNode`'s subcommands list has more than one macro leaf.
@Generable
@Operation(verb: "delete", noun: "note", description: "Delete a note")
private struct DeleteNoteCLIFixture {
    @Guide(description: "The note id")
    var id: String
}

extension DeleteNoteCLIFixture {
    func execute(in context: NotesFixtureContext) async throws -> DeleteNoteCLIOutput {
        DeleteNoteCLIOutput(id: id)
    }
}

/// JSON-encodable result produced by `ArchiveNoteCLIFixture.execute(in:)`.
private struct ArchiveNoteCLIOutput: Encodable, Sendable, Equatable {
    let id: String
    let reasonCode: Int?
    let isConfirmed: Bool
    let confidence: Double?
    let labels: [String]?
    let scores: [Int]?
    let milestonesHit: [Bool]?

    /// Keeps the wire-level JSON key as `confirmed` (matching the CLI flag
    /// and `ParamMeta` name) while the Swift property reads as an assertion
    /// per this repo's Boolean-naming convention.
    private enum CodingKeys: String, CodingKey {
        case id
        case reasonCode
        case isConfirmed = "confirmed"
        case confidence
        case labels
        case scores
        case milestonesHit
    }
}

/// `archive note` fixture: a hand-conformed `OperationDefinition` — no
/// `@Operation`/`@Generable` macro involved, mirroring the manual escape
/// hatch — under the *same* "note" noun as the macro-generated leaves above,
/// so `NounNode`'s subcommands list mixes a macro leaf and a synthesized
/// `FallbackOperationCommand` leaf. Its optional `reasonCode` (declared with
/// a `-r` short flag) exercises the fallback leaf's integer parsing and
/// short-flag/inline-equals spellings, and its `isConfirmed` boolean exercises
/// the fallback leaf's flag-presence detection. Its `confidence` exercises
/// `FallbackPayloadBuilder`'s `.number` (`Double`) scalar conversion; its
/// `labels`/`scores`/`milestonesHit` exercise `.array` conversion for
/// `[String]`/`[Int]`/`[Bool]` element types via repeated flag occurrences.
/// `relatedNoteIdGroups` is declared only in `parameterMetadata`, with no
/// matching stored property here — a nested-array (`[[String]]`) parameter
/// can never successfully convert (see `convertedArray`'s documented
/// contract), so it exercises that always-omitted branch without needing a
/// decode target. All only reachable through `FallbackPayloadBuilder`, never
/// a macro-generated `@Option`/`@Flag`.
private struct ArchiveNoteCLIFixture: OperationDefinition {
    typealias Context = NotesFixtureContext
    typealias Output = ArchiveNoteCLIOutput

    var id: String
    var reasonCode: Int?
    var isConfirmed: Bool
    var confidence: Double?
    var labels: [String]?
    var scores: [Int]?
    var milestonesHit: [Bool]?

    static let verb = "archive"
    static let noun = "note"
    static let operationDescription = "Archive a note"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The note id"),
        ParamMeta(
            name: "reasonCode", type: .integer, required: false, description: "Why the note was archived", short: "r"
        ),
        ParamMeta(name: "confirmed", type: .boolean, required: true, description: "Whether the archive was confirmed"),
        ParamMeta(
            name: "confidence", type: .number, required: false, description: "Confidence score for the archive decision"
        ),
        ParamMeta(
            name: "labels", type: .array(of: .string), required: false, description: "Labels to attach to the archived note"
        ),
        ParamMeta(
            name: "scores", type: .array(of: .integer), required: false, description: "Scores recorded for the archived note"
        ),
        ParamMeta(
            name: "milestonesHit", type: .array(of: .boolean), required: false, description: "Which milestones were hit"
        ),
        ParamMeta(
            name: "relatedNoteIdGroups", type: .array(of: .array(of: .string)), required: false,
            description: "Nested groups of related note ids (unsupported by the CLI leaf; always omitted)"
        ),
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: ArchiveNoteCLIFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        id = try content.value(String.self, forProperty: "id")
        reasonCode = try content.value(Int?.self, forProperty: "reasonCode")
        isConfirmed = try content.value(Bool.self, forProperty: "confirmed")
        confidence = try content.value(Double?.self, forProperty: "confidence")
        labels = try? content.value([String].self, forProperty: "labels")
        scores = try? content.value([Int].self, forProperty: "scores")
        milestonesHit = try? content.value([Bool].self, forProperty: "milestonesHit")
    }

    var generatedContent: GeneratedContent {
        var properties: [(String, any ConvertibleToGeneratedContent)] = [("id", id), ("confirmed", isConfirmed)]
        if let reasonCode {
            properties.append(("reasonCode", reasonCode))
        }
        if let confidence {
            properties.append(("confidence", confidence))
        }
        if let labels {
            properties.append(("labels", labels))
        }
        if let scores {
            properties.append(("scores", scores))
        }
        if let milestonesHit {
            properties.append(("milestonesHit", milestonesHit))
        }
        return GeneratedContent(properties: properties, uniquingKeysWith: { _, new in new })
    }

    func execute(in context: NotesFixtureContext) async throws -> ArchiveNoteCLIOutput {
        ArchiveNoteCLIOutput(
            id: id,
            reasonCode: reasonCode,
            isConfirmed: isConfirmed,
            confidence: confidence,
            labels: labels,
            scores: scores,
            milestonesHit: milestonesHit
        )
    }
}

/// Shared `Context` for the "tasks" tool fixture below (multi-tool tests).
private struct TasksFixtureContext: Sendable {}

/// JSON-encodable result produced by `AddTaskCLIFixture.execute(in:)`.
private struct AddTaskCLIOutput: Encodable, Sendable, Equatable {
    let title: String
}

/// `add task` fixture: a second tool's single operation, for multi-tool
/// grammar tests (`<executable> <tool> <noun> <verb>`).
@Generable
@Operation(verb: "add", noun: "task", description: "Add a task")
private struct AddTaskCLIFixture {
    @Guide(description: "The task title")
    var title: String
}

extension AddTaskCLIFixture {
    func execute(in context: TasksFixtureContext) async throws -> AddTaskCLIOutput {
        AddTaskCLIOutput(title: title)
    }
}

/// Builds the "notes" tool: two macro-generated leaves and one macro-less
/// (fallback) leaf, all under the "note" noun.
private func makeNotesTool() throws -> OperationTool<NotesFixtureContext> {
    try OperationTool(
        name: "notes",
        description: "Note operations",
        context: NotesFixtureContext(),
        operations: [
            AnyOperation(AddNoteCLIFixture.self),
            AnyOperation(DeleteNoteCLIFixture.self),
            AnyOperation(ArchiveNoteCLIFixture.self),
        ]
    )
}

/// Builds the "tasks" tool: a single macro-generated leaf under the "task"
/// noun.
private func makeTasksTool() throws -> OperationTool<TasksFixtureContext> {
    try OperationTool(
        name: "tasks",
        description: "Task operations",
        context: TasksFixtureContext(),
        operations: [AnyOperation(AddTaskCLIFixture.self)]
    )
}

/// A single-tool driver: the collapsed `<executable> <noun> <verb>` grammar
/// (`notes note add …`, per plan.md's acceptance example).
private func makeSingleToolDriver() throws -> OperationCLIDriver {
    try OperationCLIDriver(tool: makeNotesTool(), executableName: "notes")
}

/// A two-tool driver: the `<executable> <tool> <noun> <verb>` grammar.
private func makeMultiToolDriver() throws -> OperationCLIDriver {
    try OperationCLIDriver(
        tools: [AnyOperationTool(try makeNotesTool()), AnyOperationTool(try makeTasksTool())],
        executableName: "multitool"
    )
}

// MARK: - Convergence contract: argv -> payload round-trip

@Suite struct CLIDriverConvergenceTests {

    @Test func executesAddNoteAndPrintsItsJSON() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add", "--title", "Hi", "--tags", "a", "--tags", "b"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Hi\""))
        #expect(result.output.contains("\"tags\":[\"a\",\"b\"]"))
    }

    @Test func repeatedOptionValuesAccumulateIntoAnArray() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add", "--title", "Hi", "--tags", "a", "--tags", "b", "--tags", "c"])

        #expect(result.output.contains("\"tags\":[\"a\",\"b\",\"c\"]"))
    }

    @Test func inlineEqualsValueIsAccepted() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add", "--title=Hi"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Hi\""))
    }

    @Test func combinedShortFlagsSetBothBooleans() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add", "--title", "Hi", "-pu"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"pinned\":true"))
        #expect(result.output.contains("\"urgent\":true"))
    }

    @Test func terminatorDoesNotBreakParsing() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "delete", "--id", "note-1", "--"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"id\":\"note-1\""))
    }
}

// MARK: - Macro-less fallback leaf

@Suite struct CLIDriverFallbackLeafTests {

    @Test func fallbackLeafRoundTripsToTheSamePayloadTheResolverAccepts() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"id\":\"note-1\""))

        // `result.output` is the *executed* operation's JSON, not a fresh
        // payload — the actual round-trip claim is that feeding it back in
        // as a payload for the same operation is something
        // `OperationResolver.resolveParameters` (the same resolution
        // `OperationTool.call` runs every payload through) accepts: every
        // required parameter is found, and the resolved `id` matches what
        // was sent, unchanged by the trip through JSON and back.
        let reparsedOutput = try GeneratedContent(json: result.output)
        let resolution = OperationResolver().resolveParameters(reparsedOutput, matching: ArchiveNoteCLIFixture.parameterMetadata)

        #expect(resolution.missingRequired.isEmpty)
        #expect(try resolution.content.value(String.self, forProperty: "id") == "note-1")
    }

    @Test func fallbackLeafAppearsInNounHelp() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "--help"])

        #expect(result.output.contains("archive"))
    }

    @Test func fallbackLeafOwnHelpDescribesItsParameters() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--help"])

        #expect(result.output.contains("Archive a note"))
        #expect(result.output.contains("--id"))
    }

    @Test func fallbackLeafParsesAnIntegerParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1", "--reasonCode", "42"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"reasonCode\":42"))
    }

    @Test func fallbackLeafOmitsAnUnsuppliedOptionalIntegerParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1"])

        #expect(result.exitCode == 0)
        // `JSONEncoder`'s synthesized encoding for an `Optional` property
        // omits the key entirely when `nil`, rather than writing `null`.
        #expect(result.output.contains("reasonCode") == false)
    }

    @Test func fallbackLeafBooleanFlagPresenceSetsTheFieldTrue() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1", "--confirmed"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"confirmed\":true"))
    }

    @Test func fallbackLeafBooleanFlagAbsenceLeavesTheFieldFalse() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"confirmed\":false"))
    }

    @Test func fallbackLeafAcceptsTheInlineEqualsFormForAScalarParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1", "--reasonCode=42"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"reasonCode\":42"))
    }

    @Test func fallbackLeafAcceptsAShortFlagSpellingWithAValue() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1", "-r", "42"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"reasonCode\":42"))
    }

    @Test func fallbackLeafParsesANumberParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1", "--confidence", "42.5"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"confidence\":42.5"))
    }

    @Test func fallbackLeafOmitsAnUnsuppliedOptionalNumberParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("confidence") == false)
    }

    @Test func fallbackLeafParsesARepeatedStringArrayParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(
            arguments: ["note", "archive", "--id", "note-1", "--labels", "urgent", "--labels", "reviewed"]
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"labels\":[\"urgent\",\"reviewed\"]"))
    }

    @Test func fallbackLeafParsesARepeatedIntegerArrayParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(
            arguments: ["note", "archive", "--id", "note-1", "--scores", "1", "--scores", "2", "--scores", "3"]
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"scores\":[1,2,3]"))
    }

    @Test func fallbackLeafParsesARepeatedBooleanArrayParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(
            arguments: ["note", "archive", "--id", "note-1", "--milestonesHit", "true", "--milestonesHit", "false"]
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"milestonesHit\":[true,false]"))
    }

    @Test func fallbackLeafOmitsAnUnsuppliedOptionalArrayParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "archive", "--id", "note-1"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("labels") == false)
    }
}

// MARK: - Fallback leaf direct invocation (bypassing `OperationCLIDriver`)

/// Captures everything written to the process's real standard output file
/// descriptor while `body` runs.
///
/// `FallbackOperationCommand.run()` (like the macro-generated `Command.run()`
/// it mirrors) communicates its result purely via a hardcoded top-level
/// `print(...)` call — there's no injectable output stream to substitute for
/// a test double, so the only way to observe it is redirecting the real fd 1
/// a `print` call ultimately writes to, exactly as `AssertExecuteCommand` in
/// swift-argument-parser's own test helpers does via a subprocess `Pipe`.
/// This does it in-process instead, since `FallbackOperationCommand` is an
/// internal type with no standalone executable to spawn.
private func captureStandardOutput(_ body: () async throws -> Void) async throws -> String {
    let pipe = Pipe()
    let savedStdoutFD = dup(FileHandle.standardOutput.fileDescriptor)
    fflush(stdout)
    dup2(pipe.fileHandleForWriting.fileDescriptor, FileHandle.standardOutput.fileDescriptor)

    func restoreStandardOutput() {
        fflush(stdout)
        dup2(savedStdoutFD, FileHandle.standardOutput.fileDescriptor)
        close(savedStdoutFD)
        try? pipe.fileHandleForWriting.close()
    }

    do {
        try await body()
    } catch {
        restoreStandardOutput()
        throw error
    }

    restoreStandardOutput()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    try? pipe.fileHandleForReading.close()
    return String(data: data, encoding: .utf8) ?? ""
}

@Suite struct FallbackOperationCommandRunTests {

    @Test func runPrintsTheSameJSONOperationPayloadWouldProduce() async throws {
        var command = FallbackOperationCommand<ArchiveNoteCLIFixture>()
        command.rawArguments = ["--id", "note-1", "--reasonCode", "42"]
        let expectedJSON = command.operationPayload().jsonString

        let output = try await captureStandardOutput {
            try await command.run()
        }

        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedJSON)
    }

    @Test func nestedArrayParameterConvertsToNilAndIsOmittedFromThePayload() async throws {
        var command = FallbackOperationCommand<ArchiveNoteCLIFixture>()
        command.rawArguments = ["--id", "note-1", "--relatedNoteIdGroups", "a", "--relatedNoteIdGroups", "b"]

        let payloadJSON = command.operationPayload().jsonString

        #expect(payloadJSON.contains("relatedNoteIdGroups") == false)
    }
}

// MARK: - Help snapshots (single tool)

@Suite struct CLIDriverHelpTests {

    @Test func rootHelpListsEveryNoun() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["--help"])

        #expect(result.output.contains("note"))
    }

    @Test func nounHelpListsEveryVerbWithTheCorrectUsagePrefix() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "--help"])

        #expect(result.output.contains("add"))
        #expect(result.output.contains("delete"))
        #expect(result.output.contains("archive"))
        #expect(result.output.contains("USAGE: notes note <subcommand>"))
    }

    @Test func verbHelpShowsGuideDescriptionsAndTheCorrectUsagePrefix() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add", "--help"])

        #expect(result.output.contains("The note title"))
        #expect(result.output.contains("Tags to attach"))
        #expect(result.output.contains("USAGE: notes note add"))
    }
}

// MARK: - Bare root (`runNonOperationCommand`'s async branch)

@Suite struct CLIDriverBareRootTests {

    @Test func noArgumentsAtAllShowsRootHelpWithASuccessExitCode() async throws {
        let driver = try makeSingleToolDriver()

        // No arguments at all: `RootCommand` itself (an `AsyncParsableCommand`,
        // not an `OperationCommand`) is the value `asyncParseAsRoot` returns —
        // no subcommand was consumed, so parsing stops there rather than
        // descending into `note`. That drives `dispatch(command:)` to
        // `runNonOperationCommand`'s `if var asyncCommand = mutableCommand as?
        // AsyncParsableCommand` branch, exercising the async `run()` call.
        // `RootCommand`'s default `run()` (inherited from `ParsableCommand`,
        // since ArgumentParser's `AsyncParsableCommand` has no separate
        // default) unconditionally throws `CleanExit.helpRequest(self)`, so
        // this still lands in `runNonOperationCommand`'s `catch`, not its
        // `CLIResult(output: "", exitCode: 0)` success return — but it is the
        // only way to reach the async branch at all, since every other
        // non-`OperationCommand` node in the tree (`NounNode`/`ToolNode`/
        // ArgumentParser's built-in `HelpCommand`) is a synchronous
        // `ParsableCommand`, not `AsyncParsableCommand`.
        let result = await driver.run(arguments: [])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("note"))
    }
}

// MARK: - `--generate-completion-script`

@Suite struct CLIDriverCompletionTests {

    @Test func completionScriptContainsEveryNounVerbAndFlag() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["--generate-completion-script", "zsh"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("note"))
        #expect(result.output.contains("add"))
        #expect(result.output.contains("delete"))
        #expect(result.output.contains("archive"))
        #expect(result.output.contains("--title"))
        #expect(result.output.contains("--tags"))
    }

    @Test func completionScriptIncludesTheMacroLessFallbackLeafsFlags() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["--generate-completion-script", "zsh"])

        #expect(result.output.contains("archive note: --id"))
    }

    @Test func inlineEqualsShellFormIsAccepted() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["--generate-completion-script=zsh"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("note"))
    }
}

// MARK: - Multi-tool grammar

@Suite struct CLIDriverMultiToolTests {

    @Test func singleToolCollapsesTheToolLevelAway() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add", "--title", "Hi"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Hi\""))
    }

    @Test func multiToolRequiresTheToolLevelSegment() async throws {
        let driver = try makeMultiToolDriver()

        let result = await driver.run(arguments: ["notes", "note", "add", "--title", "Hi"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Hi\""))
    }

    @Test func multiToolDispatchesTheSecondToolsOperation() async throws {
        let driver = try makeMultiToolDriver()

        let result = await driver.run(arguments: ["tasks", "task", "add", "--title", "Groceries"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Groceries\""))
    }

    @Test func multiToolRootHelpListsEveryToolName() async throws {
        let driver = try makeMultiToolDriver()

        let result = await driver.run(arguments: ["--help"])

        #expect(result.output.contains("notes"))
        #expect(result.output.contains("tasks"))
    }

    @Test func duplicateToolNamesAreRejectedAtInit() throws {
        let tool = try makeNotesTool()

        do {
            _ = try OperationCLIDriver(tools: [AnyOperationTool(tool), AnyOperationTool(tool)])
            Issue.record("expected OperationCLIDriverError.duplicateToolName to be thrown")
        } catch let error as OperationCLIDriverError {
            #expect(error == .duplicateToolName("notes"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func toolNamesDifferingOnlyByCaseAreNotTreatedAsDuplicates() throws {
        let lowercaseTool = try OperationTool(
            name: "notes",
            description: "Note operations",
            context: NotesFixtureContext(),
            operations: [AnyOperation(AddNoteCLIFixture.self)]
        )
        let uppercaseTool = try OperationTool(
            name: "Notes",
            description: "Other note operations",
            context: NotesFixtureContext(),
            operations: [AnyOperation(DeleteNoteCLIFixture.self)]
        )

        // Case-sensitive tool-name matching: "notes" and "Notes" must both
        // be accepted, not rejected as duplicates. A thrown
        // `OperationCLIDriverError.duplicateToolName` here would fail this
        // test by propagating out of the `throws` test function.
        _ = try OperationCLIDriver(tools: [AnyOperationTool(lowercaseTool), AnyOperationTool(uppercaseTool)])
    }
}

// MARK: - Per-tool operation validation

@Suite struct CLIDriverOperationValidationTests {

    @Test func twoOperationsSharingAnOpStringAreRejectedAtInit() throws {
        let tool = try OperationTool(
            name: "notes",
            description: "Note operations",
            context: NotesFixtureContext(),
            operations: [AnyOperation(AddNoteCLIFixture.self), AnyOperation(AddNoteCLIFixture.self)]
        )

        do {
            _ = try OperationCLIDriver(tool: tool)
            Issue.record("expected OperationCLIDriverError.duplicateOperation to be thrown")
        } catch let error as OperationCLIDriverError {
            #expect(error == .duplicateOperation(tool: "notes", opString: "add note"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

// MARK: - Error cases

@Suite struct CLIDriverErrorTests {

    @Test func unknownNounReturnsAnErrorWithNonZeroExitCode() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["notanoun", "add"])

        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
    }

    @Test func unknownVerbReturnsAnErrorWithNonZeroExitCode() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "notaverb"])

        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
    }

    @Test func missingRequiredParameterReturnsAnErrorNamingIt() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add"])

        #expect(result.exitCode != 0)
        #expect(result.output.contains("title"))
    }

    @Test func badIntValueReturnsAnErrorNamingTheParameter() async throws {
        let driver = try makeSingleToolDriver()

        let result = await driver.run(arguments: ["note", "add", "--title", "Hi", "--priority", "not-a-number"])

        #expect(result.exitCode != 0)
        #expect(result.output.contains("priority"))
    }
}

// MARK: - `OperationCLIDriverError.description`

@Suite struct OperationCLIDriverErrorDescriptionTests {

    @Test func duplicateToolNameDescribesTheOffendingName() {
        let error = OperationCLIDriverError.duplicateToolName("x")

        #expect(
            error.description
                == "duplicate tool name 'x': every tool passed to OperationCLIDriver must have a unique name"
        )
    }

    @Test func emptyToolDescribesTheOffendingName() {
        let error = OperationCLIDriverError.emptyTool("x")

        #expect(
            error.description == "tool 'x' has no operations: OperationCLIDriver requires at least one operation per tool"
        )
    }

    @Test func duplicateOperationDescribesTheToolAndOperation() {
        let error = OperationCLIDriverError.duplicateOperation(tool: "x", opString: "y")

        #expect(
            error.description
                == "tool 'x' declares 'y' more than once: every operation's verb/noun pair must be unique within a tool"
        )
    }
}
