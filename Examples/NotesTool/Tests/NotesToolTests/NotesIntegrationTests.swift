import FoundationModels
import FoundationModelsExtras
import Operations
import OperationsCLI
import Testing

@testable import NotesToolCore

/// Exercises every notes operation through `AnyOperation`/`OperationTool.call`
/// (the model-facing path), sharing one `OperationTool` instance per test so
/// a later call observes state an earlier call left behind — proving the ops
/// actually mutate the shared `NotesStore` `NotesTool.make()` wires up, not
/// just that each call individually returns plausible JSON.
@Suite struct NotesDispatchIntegrationTests {

    @Test func addNoteDispatchesThroughAnyOperationAndReturnsTheStoredFields() async throws {
        let tool = try NotesTool.make()

        let json = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "add note", "title": "Groceries", "body": "Milk, eggs, bread", "tags": ["errands"],
            ])
        )

        #expect(json.contains("\"id\":\"note-1\""))
        #expect(json.contains("\"title\":\"Groceries\""))
        #expect(json.contains("\"body\":\"Milk, eggs, bread\""))
        #expect(json.contains("\"tags\":[\"errands\"]"))
    }

    @Test func addedNoteIsVisibleToASubsequentListNoteCall() async throws {
        let tool = try NotesTool.make()
        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "add note", "title": "Groceries"]))

        let json = try await tool.call(arguments: GeneratedContent(properties: ["op": "list note"]))

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func listNoteOnAnEmptyStoreReturnsAnEmptyArray() async throws {
        let tool = try NotesTool.make()

        let json = try await tool.call(arguments: GeneratedContent(properties: ["op": "list note"]))

        #expect(json == "[]")
    }

    @Test func listNotePreservesInsertionOrder() async throws {
        let tool = try NotesTool.make()
        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "add note", "title": "First"]))
        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "add note", "title": "Second"]))

        let json = try await tool.call(arguments: GeneratedContent(properties: ["op": "list note"]))

        let firstRange = try #require(json.range(of: "First"))
        let secondRange = try #require(json.range(of: "Second"))
        #expect(firstRange.lowerBound < secondRange.lowerBound)
    }

    @Test func getNoteReturnsThePreviouslyAddedNote() async throws {
        let tool = try NotesTool.make()
        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "add note", "title": "Groceries"]))

        let json = try await tool.call(arguments: GeneratedContent(properties: ["op": "get note", "id": "note-1"]))

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func getNoteOnAnUnknownIDThrowsAnExecutionFailedError() async throws {
        let tool = try NotesTool.make()

        do {
            _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "get note", "id": "missing"]))
            Issue.record("expected OperationError.executionFailed to be thrown")
        } catch let error as OperationError {
            #expect(error == .executionFailed(cause: NotesError.notFound(id: "missing")))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func deleteNoteRemovesItFromASubsequentListNoteCall() async throws {
        let tool = try NotesTool.make()
        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "add note", "title": "Groceries"]))

        let deleteJSON = try await tool.call(arguments: GeneratedContent(properties: ["op": "delete note", "id": "note-1"]))
        #expect(deleteJSON.contains("\"id\":\"note-1\""))

        let listJSON = try await tool.call(arguments: GeneratedContent(properties: ["op": "list note"]))
        #expect(listJSON == "[]")
    }

    @Test func deleteNoteOnAnUnknownIDThrowsAnExecutionFailedError() async throws {
        let tool = try NotesTool.make()

        do {
            _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "delete note", "id": "missing"]))
            Issue.record("expected OperationError.executionFailed to be thrown")
        } catch let error as OperationError {
            #expect(error == .executionFailed(cause: NotesError.notFound(id: "missing")))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func tagNoteAppendsNewTagsToAnExistingNote() async throws {
        let tool = try NotesTool.make()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "add note", "title": "Groceries", "tags": ["errands"]])
        )

        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "tag note", "id": "note-1", "tags": ["errands", "urgent"]])
        )

        #expect(json.contains("\"tags\":[\"errands\",\"urgent\"]"))
    }

    @Test func tagNoteOnAnUnknownIDThrowsAnExecutionFailedError() async throws {
        let tool = try NotesTool.make()

        do {
            _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "tag note", "id": "missing", "tags": ["urgent"]]))
            Issue.record("expected OperationError.executionFailed to be thrown")
        } catch let error as OperationError {
            #expect(error == .executionFailed(cause: NotesError.notFound(id: "missing")))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

/// Exercises the `OperationDescribing` conformance of the real notes tool, as
/// a host that holds only `any Tool` sees it.
@Suite struct NotesOperationDescribingTests {

    private func makeDescribingTool() throws -> any OperationDescribing {
        let tool: any Tool = try NotesTool.make()
        return try #require(tool as? any OperationDescribing)
    }

    @Test func notesToolListsItsFiveOperationDescriptors() throws {
        let tool = try makeDescribingTool()

        #expect(tool.operationDescriptors.map(\.opString) == ["add note", "get note", "list note", "delete note", "tag note"])
    }

    @Test func addNoteDescriptorMarksOnlyTitleAsRequired() throws {
        let tool = try makeDescribingTool()

        let addNote = try #require(tool.operationDescriptors.first { $0.opString == "add note" })
        let requiredByName = Dictionary(uniqueKeysWithValues: addNote.parameters.map { ($0.name, $0.required) })

        #expect(requiredByName == ["title": true, "body": false, "tags": false])
    }

    @Test func tagNoteDescriptorMarksTagsAsRequired() throws {
        let tool = try makeDescribingTool()

        let tagNote = try #require(tool.operationDescriptors.first { $0.opString == "tag note" })
        let tags = try #require(tagNote.parameters.first { $0.name == "tags" })

        #expect(tags.required)
    }

    @Test func performTagNoteGivesTheSameJSONAsCall() async throws {
        let addNote = GeneratedContent(properties: ["op": "add note", "title": "Groceries"])
        let tagNote = GeneratedContent(properties: ["op": "tag note", "id": "note-1", "tags": ["a"]])
        let performingTool = try NotesTool.make()
        let callingTool = try NotesTool.make()
        _ = try await performingTool.perform(addNote)
        _ = try await callingTool.call(arguments: addNote)

        let performed = try await performingTool.perform(tagNote)
        let called = try await callingTool.call(arguments: tagNote)

        #expect(performed == called)
        #expect(performed.contains("\"tags\":[\"a\"]"))
    }
}

/// Exercises `NotesError` directly, independent of dispatch — the
/// `NotesDispatchIntegrationTests` "unknown id" tests above only assert the
/// error surfaces as `OperationError.executionFailed`, never reading
/// `NotesError`'s own `CustomStringConvertible.description`.
@Suite struct NotesErrorTests {

    @Test func notFoundDescriptionNamesTheMissingID() {
        let error = NotesError.notFound(id: "abc")

        #expect(error.description == "No note found with id 'abc'.")
    }
}

/// Exercises every notes operation through `OperationCLIDriver`, proving the
/// macro-generated `Command` leaves converge on the identical dispatch path
/// the model-facing tests above exercise directly.
@Suite struct NotesCLIIntegrationTests {

    private func makeDriver() throws -> OperationCLIDriver {
        try OperationCLIDriver(tool: try NotesTool.make(), executableName: "notes")
    }

    @Test func addNoteThroughTheCLIPrintsTheStoredNoteAsJSON() async throws {
        let driver = try makeDriver()

        let result = await driver.run(arguments: ["note", "add", "--title", "Groceries"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Groceries\""))
    }

    @Test func addThenListThroughTheCLIReflectsTheStoredNote() async throws {
        let driver = try makeDriver()
        _ = await driver.run(arguments: ["note", "add", "--title", "Groceries"])

        let result = await driver.run(arguments: ["note", "list"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Groceries\""))
    }

    @Test func addThenGetThroughTheCLIReturnsTheSameNote() async throws {
        let driver = try makeDriver()
        _ = await driver.run(arguments: ["note", "add", "--title", "Groceries"])

        let result = await driver.run(arguments: ["note", "get", "--id", "note-1"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"title\":\"Groceries\""))
    }

    @Test func addThenDeleteThroughTheCLIRemovesTheNote() async throws {
        let driver = try makeDriver()
        _ = await driver.run(arguments: ["note", "add", "--title", "Groceries"])

        let result = await driver.run(arguments: ["note", "delete", "--id", "note-1"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"id\":\"note-1\""))
    }

    @Test func addThenTagThroughTheCLIAttachesTheTag() async throws {
        let driver = try makeDriver()
        _ = await driver.run(arguments: ["note", "add", "--title", "Groceries"])

        let result = await driver.run(arguments: ["note", "tag", "--id", "note-1", "--tags", "urgent"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"tags\":[\"urgent\"]"))
    }

    @Test func getOnAnUnknownIDThroughTheCLIReturnsANonZeroExitCode() async throws {
        let driver = try makeDriver()

        let result = await driver.run(arguments: ["note", "get", "--id", "missing"])

        #expect(result.exitCode != 0)
    }

    @Test func rootHelpListsTheNoteNoun() async throws {
        let driver = try makeDriver()

        let result = await driver.run(arguments: ["--help"])

        #expect(result.output.contains("note"))
    }

    @Test func nounHelpListsEveryVerb() async throws {
        let driver = try makeDriver()

        let result = await driver.run(arguments: ["note", "--help"])

        #expect(result.output.contains("add"))
        #expect(result.output.contains("get"))
        #expect(result.output.contains("list"))
        #expect(result.output.contains("delete"))
        #expect(result.output.contains("tag"))
    }
}
