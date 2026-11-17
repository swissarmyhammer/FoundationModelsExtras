import FoundationModels
import Testing

@testable import Operations

/// Records each operation that runs, so a test can tell whether a call ran
/// an operation and which one.
private actor EntryRunLog {
    /// The op string of each operation that ran, in run order.
    private(set) var runs: [String] = []

    /// Records that the operation with `opString` ran.
    ///
    /// - Parameter opString: The op string of the operation that ran.
    func record(_ opString: String) {
        runs.append(opString)
    }
}

/// The shared context of the entry fixtures. It holds the run log.
private struct EntryContext: Sendable {
    /// The log that each fixture operation writes to when it runs.
    let log = EntryRunLog()
}

/// What each entry fixture answers: the op string of the operation that ran.
private struct EntryRunOutput: Encodable, Sendable {
    let op: String
}

/// `get entry`: it only reads, so it declares with a static that key-fit
/// inference can choose it.
@Generable
@Operation(verb: "get", noun: "entry", description: "Get one entry")
private struct GetEntryFixture {
    static let isInferable = true

    @Guide(description: "The entry name")
    var name: String
}

/// `list entry`: it only reads, so it declares with the macro argument that
/// key-fit inference can choose it.
@Generable
@Operation(verb: "list", noun: "entry", description: "List the entries", isInferable: true)
private struct ListEntryFixture {
    @Guide(description: "Text that a listed entry must hold")
    var filter: String?
}

/// `delete entry`: it has a side effect, so it keeps the default and only an
/// explicit `op` runs it. Only this operation has `reason`.
@Generable
@Operation(verb: "delete", noun: "entry", description: "Delete one entry")
private struct DeleteEntryFixture {
    @Guide(description: "The entry name")
    var name: String

    @Guide(description: "Why the entry is deleted")
    var reason: String?

    @Guide(description: "Delete the entry when it is locked")
    var force: Bool?
}

/// `archive entry`: it has a side effect, so it keeps the default. Its keys
/// are a subset of the keys of `delete entry`.
@Generable
@Operation(verb: "archive", noun: "entry", description: "Archive one entry")
private struct ArchiveEntryFixture {
    @Guide(description: "The entry name")
    var name: String

    @Guide(description: "Archive the entry when it is locked")
    var force: Bool?
}

/// `remove entry`: it has a side effect, so it keeps the default. Its verb
/// `remove` is a key of the default verb-alias table, which maps it to
/// `delete`.
@Generable
@Operation(verb: "remove", noun: "entry", description: "Remove one entry")
private struct RemoveEntryFixture {
    @Guide(description: "The entry name")
    var name: String
}

/// One operation of the entry tool. A conforming type states only its verb,
/// noun, and parameters. This extension gives the `execute(in:)` that records
/// the run and answers with the op string.
private protocol EntryOperation: OperationDefinition
where Context == EntryContext, Output == EntryRunOutput {}

extension EntryOperation {
    /// Records the op string of this operation in the run log, and answers
    /// with it.
    ///
    /// - Parameter context: The context that holds the run log.
    /// - Returns: The op string of this operation.
    func execute(in context: EntryContext) async throws -> EntryRunOutput {
        await context.log.record(Self.opString)
        return EntryRunOutput(op: Self.opString)
    }
}

extension GetEntryFixture: EntryOperation {}

extension ListEntryFixture: EntryOperation {}

extension DeleteEntryFixture: EntryOperation {}

extension ArchiveEntryFixture: EntryOperation {}

extension RemoveEntryFixture: EntryOperation {}

/// Key-fit inference and `defaultOp` choose only an operation that declares
/// `isInferable`. An op-less call that fits only other operations does not
/// run, and it gets an error that tells the caller to name the operation.
@Suite("OperationTool inference safety")
struct OperationInferenceSafetyTests {
    /// The context of the tool under test. Each test reads its run log.
    private let context = EntryContext()

    /// Makes the entry tool over `context`.
    ///
    /// - Parameter defaultOp: The default op of the resolver, or `nil` for
    ///   none.
    /// - Returns: The fused tool.
    private func makeEntryTool(defaultOp: String? = nil) throws -> OperationTool<EntryContext> {
        try OperationTool(
            name: "entries",
            description: "Reads and changes entries",
            context: context,
            operations: [
                AnyOperation(GetEntryFixture.self),
                AnyOperation(ListEntryFixture.self),
                AnyOperation(DeleteEntryFixture.self),
                AnyOperation(ArchiveEntryFixture.self),
            ],
            resolver: OperationResolver(defaultOp: defaultOp)
        )
    }

    /// Makes a tool over `context` with the default resolver and the given
    /// operations.
    ///
    /// - Parameter operations: The operations of the tool.
    /// - Returns: The fused tool.
    private func makeTool(_ operations: [AnyOperation<EntryContext>]) throws -> OperationTool<EntryContext> {
        try OperationTool(
            name: "entries",
            description: "Reads and changes entries",
            context: context,
            operations: operations,
            resolver: OperationResolver()
        )
    }

    /// The op strings of every operation of `tool`, in tool order.
    private func validOps(of tool: OperationTool<EntryContext>) -> [String] {
        tool.operations.map(\.opString)
    }

    // MARK: - The flag

    @Test func operationIsNotInferableByDefault() {
        #expect(!ArchiveEntryFixture.isInferable)
    }

    @Test func anyOperationCarriesTheFlagOfItsOperation() {
        #expect(AnyOperation(GetEntryFixture.self).isInferable)
    }

    // MARK: - Missing `op`

    @Test func opLessCallThatFitsOnlyADestructiveOperationDoesNotRunIt() async throws {
        let tool = try makeEntryTool()

        _ = try await tool.call(arguments: GeneratedContent(properties: ["name": "alpha", "reason": "old"]))

        #expect(await context.log.runs.isEmpty)
    }

    @Test func opLessCallThatFitsOnlyADestructiveOperationGetsTheErrorThatNamesIt() async throws {
        let tool = try makeEntryTool()

        let message = try await tool.call(arguments: GeneratedContent(properties: ["name": "alpha", "reason": "old"]))

        #expect(message == OperationError.unnamedOperation(fitting: ["delete entry"], valid: validOps(of: tool)).description)
    }

    @Test func opLessCallThatFitsOnlyAnInferableOperationRunsIt() async throws {
        let tool = try makeEntryTool()

        _ = try await tool.call(arguments: GeneratedContent(properties: ["filter": "al"]))

        #expect(await context.log.runs == ["list entry"])
    }

    @Test func opLessCallThatFitsAnInferableAndADestructiveOperationRunsTheInferableOne() async throws {
        let tool = try makeEntryTool()

        _ = try await tool.call(arguments: GeneratedContent(properties: ["name": "alpha"]))

        #expect(await context.log.runs == ["get entry"])
    }

    @Test func defaultOpThatNamesANonInferableOperationIsNotUsed() async throws {
        let tool = try makeEntryTool(defaultOp: "delete entry")

        _ = try await tool.call(arguments: GeneratedContent(properties: ["name": "alpha", "force": true]))

        #expect(await context.log.runs.isEmpty)
    }

    @Test func performThrowsTheErrorForAnOpLessCallThatFitsOnlyDestructiveOperations() async throws {
        let tool = try makeEntryTool()
        let fitting = ["delete entry", "archive entry"]

        await #expect(throws: OperationError.unnamedOperation(fitting: fitting, valid: validOps(of: tool))) {
            try await tool.perform(GeneratedContent(properties: ["name": "alpha", "force": true]))
        }
    }

    // MARK: - The error text

    @Test func unnamedOperationTextTellsTheCallerToNameTheOpAndListsTheFitsAndTheValidOps() {
        let error = OperationError.unnamedOperation(fitting: ["delete entry"], valid: ["get entry", "delete entry"])

        #expect(
            error.description
                == "No operation is named. Name the operation in `op`. "
                + "Operations whose parameters fit the given keys: delete entry. "
                + "Valid operations: get entry, delete entry.")
    }

    @Test func unnamedOperationTextWithNoFitListsOnlyTheValidOps() {
        let error = OperationError.unnamedOperation(fitting: [], valid: ["get entry", "delete entry"])

        #expect(
            error.description
                == "No operation is named. Name the operation in `op`. Valid operations: get entry, delete entry.")
    }

    // MARK: - Explicit `op`

    @Test func explicitOpOfADestructiveOperationRunsIt() async throws {
        let tool = try makeEntryTool()

        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "delete entry", "name": "alpha"]))

        #expect(await context.log.runs == ["delete entry"])
    }

    @Test func explicitOpWithAVerbThatIsAnAliasKeyRunsTheOperationWithThatVerb() async throws {
        let tool = try makeTool([AnyOperation(RemoveEntryFixture.self)])

        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "remove entry", "name": "alpha"]))

        #expect(await context.log.runs == ["remove entry"])
    }

    @Test(arguments: ["remove entry", "delete entry"])
    func explicitOpRunsTheOperationItNamesWhenTheAliasTargetAlsoExists(op: String) async throws {
        let tool = try makeTool([AnyOperation(RemoveEntryFixture.self), AnyOperation(DeleteEntryFixture.self)])

        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": op, "name": "alpha"]))

        #expect(await context.log.runs == [op])
    }

    @Test func explicitOpWithAnAliasVerbRunsTheAliasTargetWhenNoOperationHasTheVerb() async throws {
        let tool = try makeEntryTool()

        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "remove entry", "name": "alpha"]))

        #expect(await context.log.runs == ["delete entry"])
    }

    @Test func opLessCallDoesNotRunAnOperationWhoseVerbIsAnAliasKey() async throws {
        let tool = try makeTool([AnyOperation(RemoveEntryFixture.self)])

        let message = try await tool.call(arguments: GeneratedContent(properties: ["name": "alpha"]))

        #expect(await context.log.runs.isEmpty)
        #expect(message == OperationError.unnamedOperation(fitting: ["remove entry"], valid: validOps(of: tool)).description)
    }
}
