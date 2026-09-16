---
assignees:
- claude-code
depends_on:
- 01M2N2AH0WDTKYBC7BMRMMV6QV
position_column: todo
position_ordinal: '8180'
title: Conform OperationTool to OperationDescribing with a throwing perform
---
Depends on ^rmmv6qv (the OperationDescribing protocol and its descriptor types).

## What
In `Sources/Operations/OperationTool.swift`, make `OperationTool<Context>` conform to `OperationDescribing` for every `Context`.
- `operationDescriptors` maps each `AnyOperation<Context>` in `operations` to an `OperationDescriptor`, in registration order. Map `ParamMeta` to `OperationParameterDescriptor` field by field, and `ParamType` to `OperationParameterType` case by case. Do not map `ParamMeta.short`, because it is only for the CLI.
- `perform(_:)` runs the same pipeline as `call(arguments:)`: `resolver.extractedOpString(from:)`, `resolver.matchOpString(_:against:)`, `resolver.resolveParameters(_:matching:)`, then `operation.run`. The differences: it throws `OperationError.unknownOperation`, `.missingRequired` and `.decodingFailed` instead of returning their text, and it does not read or change the `RetryState` actor. Move the shared resolve step out of `call` into one function that both paths use, so that the two paths cannot drift. The behavior of `call(arguments:)` must not change.
- Do not change `Sources/OperationsCLI/AnyOperationTool.swift`.
- Add a short section to `docs/OPERATIONS_DESIGN_NOTES.md` that tells why `perform` exists. A host such as FoundationModelsMultitool runs the tool in a code sandbox. There, a throw is a promise rejection that the model sees, so the rule of `call` to return, not throw, does not apply.

Source: request from the FoundationModelsMultitool planning session. Multitool's first card will update `Package.resolved` to the Extras revision that has this change after it is on `main`.

## Acceptance Criteria
- [ ] `NotesTool.make()` from `Examples/NotesTool` casts to `any OperationDescribing` and gives five descriptors with the op strings `add note`, `get note`, `list note`, `delete note`, `tag note`.
- [ ] The `AddNote` descriptor marks `title` as required, and `body` and `tags` as optional. The `TagNote` descriptor marks `tags` as required.
- [ ] `perform` with `{"op": "tag note", "id": "note-1", "tags": ["a"]}` gives the same JSON text as `call` for the same payload.
- [ ] `perform` with an unknown op throws `OperationError.unknownOperation`. `call` still returns the corrective text for the same payload.
- [ ] `perform` with a missing required field throws `OperationError.missingRequired`, and the retry cap has no effect on a later `call`.
- [ ] The full `swift test` passes, including `DocCoverageTests`.
- [ ] The change is pushed to `origin/main`, and a comment on this card names the final revision (the full commit SHA). FoundationModelsMultitool gets Extras by URL and branch `main`, not by path, so `swift package update` cannot get a local commit. The Multitool card pins `Package.resolved` to this revision.

## Tests
- [ ] `Tests/OperationsTests/OperationDescribingConformanceTests.swift`: the descriptor mapping for the `CoreTypesTests` fixture operations, each `ParamType` case, and the five `perform` cases above.
- [ ] `Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift`: one test that lists the five descriptors of the real notes tool.
- [ ] The full `swift test` passes.

## Workflow
- Use `/tdd`. #operation-tools #multitool-ask