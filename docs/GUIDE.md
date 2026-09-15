# Operations Guide

The full walkthrough for the `Operations` module: declaring an operation, fusing
`@Operation`-declared structs into a `FoundationModels.Tool`, registering it on a
`LanguageModelSession`, and driving the same operations from the dual-use CLI.

## Declaring an operation

Declare a typed operation once with `@Operation`, and get both a fused
[FoundationModels](https://developer.apple.com/documentation/foundationmodels) `Tool` and a
dual-use command-line verb for free. A struct's stored properties *are* its parameters;
behavior lives in a separate `execute(in:)`:

<!-- doc-snippet source="Examples/NotesTool/Sources/NotesToolCore/AddNote.swift" -->
```swift
/// Creates a new note, per plan.md's "Declaring an operation" example.
@Generable
@Operation(verb: "add", noun: "note", description: "Create a new note")
internal struct AddNote {
    @Guide(description: "The note title")
    @OperationParam(short: "t")
    var title: String

    @Guide(description: "Markdown body of the note")
    @OperationParam(short: "b")
    var body: String?

    @Guide(description: "Tags to attach")
    var tags: [String]?
}

extension AddNote {
    func execute(in context: NotesContext) async throws -> Note {
        await context.store.insert(title: title, body: body, tags: tags ?? [])
    }
}
```
<!-- /doc-snippet -->

`@Operation`'s expansion also emits a nested `Command: AsyncParsableCommand`, so the same
declaration drives `notes note add --title "Groceries" --tags errands` from the command line,
converging on the identical payload the model would have sent.

## Fusing operations into a Tool

`AnyOperation<Context>` type-erases an `OperationDefinition`'s associated types so a
registry can mix many operation types together. `OperationTool<Context>` fuses a set of
`AnyOperation<Context>`s sharing one `Context` into a single `FoundationModels.Tool`: its
`parameters` schema is the flat union `SchemaFusion` builds — one required `op` string
enum (every operation's `"verb noun"` string) plus the union of every operation's fields,
all declared optional, deduplicated by name across operations. Per-operation
requiredness and value constraints are enforced at dispatch instead of by the schema (see
[`OPERATIONS_DESIGN_NOTES.md`](OPERATIONS_DESIGN_NOTES.md) for why). `OperationTool.call(arguments:)`
forgivingly resolves a payload's `op` and parameter keys (case, `_`/`-`/space separators
or none in a multi-word verb or noun, `"noun verb"` reordering, verb aliases, noun
aliases, camelCase/snake_case key aliasing) to the
matching operation and dispatches to it:

<!-- doc-snippet source="Examples/NotesTool/Sources/NotesToolCore/NotesTool.swift" -->
```swift
public static func make(includesSchemaInInstructions: Bool = true) throws -> OperationTool<NotesContext> {
    try OperationTool(
        name: name,
        description: description,
        context: NotesContext(),
        operations: [
            AnyOperation(AddNote.self),
            AnyOperation(GetNote.self),
            AnyOperation(ListNotes.self),
            AnyOperation(DeleteNote.self),
            AnyOperation(TagNote.self),
        ],
        includesSchemaInInstructions: includesSchemaInInstructions
    )
}
```
<!-- /doc-snippet -->

A fused tool should carry roughly 5–15 operations, not 50+ — Apple's own guidance (TN3193)
is "provide maximum 3–5 tools" with small types and short names; partition a large domain
into a few `OperationTool`s rather than one giant one. `includesSchemaInInstructions`
controls whether the fused schema is injected into the prompt, since for a many-op tool
that's the dominant context-window cost.

## Registering with a `LanguageModelSession`

A fused `OperationTool` is a regular FoundationModels `Tool`, so it registers on a
session exactly like any other:

<!-- doc-snippet source="Examples/NotesTool/Sources/notes/ChatValidationHarness.swift" -->
```swift
let tool = try NotesTool.make()
let session = LanguageModelSession(tools: [tool], instructions: sessionInstructions)
```
<!-- /doc-snippet -->

When the tool's `call(arguments:)` can't resolve the model's payload to a known operation
(unknown op, missing required parameters, unparseable values), it *returns* a corrective
message describing the problem — rather than throwing — so the model can retry within the
same turn; a throw aborts the turn without another chance. A retry cap stops the model
from looping indefinitely on repeated corrective failures. See
`Examples/NotesTool/Sources/notes/ChatValidationHarness.swift` for a scripted,
manual-run (`swift run notes --chat`) validation of this end to end: op-call accuracy
over a prompt set, rendered schema size via `tokenCount(for:)`, and the retry-cap
behavior on a deliberately invalid prompt.

## The dual-use CLI

`OperationCLIDriver` assembles a runtime ArgumentParser command tree from one or more
`OperationTool`s' operations: `<executable> <noun> <verb>` with a single tool
(`notes note add --title Hi`), or `<executable> <tool> <noun> <verb>` with more than one.
Every leaf — whether the macro-generated `Command` or, for a hand-conformed operation, a
synthesized fallback built from `ParamMeta` — parses into the identical canonical `op` +
fields payload the model path sends, and dispatches through the exact same
`OperationTool.call(arguments:)`:

<!-- doc-snippet source="Examples/NotesTool/Sources/notes/NotesToolMain.swift" -->
```swift
private static func runCLI(arguments: [String]) async {
    do {
        let driver = try OperationCLIDriver(tool: try NotesTool.make(), executableName: NotesTool.name)
        let result = await driver.run(arguments: arguments)
        if !result.output.isEmpty {
            print(result.output)
        }
        if result.exitCode != 0 {
            exit(result.exitCode)
        }
    } catch {
        FileHandle.standardError.write(Data("notes: \(error)\n".utf8))
        exit(1)
    }
}
```
<!-- /doc-snippet -->

Because the tree is built from real `ParsableCommand` types, `--help` at every level,
did-you-mean suggestions on an unknown noun/verb, `--opt=value`, combined short flags,
`--` termination, and `--generate-completion-script` all work exactly as they would for a
hand-written ArgumentParser command tree — the runtime assembly (a freeze-once registry
populated once at `OperationCLIDriver.init`) is invisible to ArgumentParser itself. Try it
end to end:

```console
$ swift run notes note add --title "Groceries" --tags errands
$ swift run notes note list
$ swift run notes --generate-completion-script zsh
```

## Building and testing

```console
$ swift build
$ swift test
```

Requires Swift 6.2 tools and the macOS 26 / iOS 26 SDK (FoundationModels availability).
The `notes --chat` live-model mode additionally needs an Apple Intelligence–enabled
device; it degrades to a skip message everywhere else, including CI.

`Tests/OperationsTests/DocCoverageTests.swift` enforces doc coverage on every `public`
declaration in `Sources/Operations` and `Sources/OperationsCLI` as part of `swift test`.
`Examples/NotesTool/Tests/NotesToolTests/ReadmeSnippetTests.swift` checks that every code
block in this guide (marked by a `<!-- doc-snippet -->` comment) is a real,
contiguous excerpt of the source file it cites — not hand-written pseudocode that could
silently drift out of sync with what actually compiles.

## Further reading

- [`operations-plan.md`](operations-plan.md) — the full design: goals, the Rust pattern
  being ported, the decided schema-fusion shape and the evidence behind it,
  forgiving-input resolution, and the task-by-task build plan.
- [`OPERATIONS_DESIGN_NOTES.md`](OPERATIONS_DESIGN_NOTES.md) — where the implementation
  departed from that plan (and from the Rust swissarmyhammer design it ports), and why.
