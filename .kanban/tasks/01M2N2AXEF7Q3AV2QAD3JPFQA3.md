---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2n9rc76j28ctba9800rs30g
  text: |-
    Research done.
    - `OperationDescribing` and the descriptor types are in the core module `FoundationModelsExtras` (`Sources/FoundationModelsExtras/OperationEvents/OperationDescribing.swift`). `Operations` already imports that module. The card does not ask for `Operations` typealiases, so the tests use `import FoundationModelsExtras`.
    - `call(arguments:)` today does the resolve step in two places: the private `matchOperation(for:)` and a `resolver.resolveParameters` call. Plan: one private function `resolve(_:)` with typed throws `OperationError` that gives the operation and the resolved content. `call` catches the error and returns `recordCorrective(error.description)`. `perform` lets the error go out. Only `call` touches `RetryState`.
    - The fixture operations in `CoreTypesTests.swift` are `private`. The new test file cannot see them. Plan: remove `private` from `FixtureContext`, `FixtureOutput`, `FixtureOperation`, `FailingEncodeOutput` and `FailingEncodeOperation`. No other test file declares these names.
    - `Tests/OperationsTests` cannot import `NotesToolCore`, so the `tag note` payload cases use a local `tag note` fixture there, and `NotesIntegrationTests.swift` also checks `perform` against `call` on the real notes tool.
  timestamp: 2026-09-16T14:25:57.990386+00:00
- actor: claude-code
  id: 01m2nabp0mk4whvn8g8qcznr2s
  text: |-
    ### implement — changed
    - TDD: RED was a compile failure of the new tests ("value of type 'OperationTool<FixtureContext>' has no member 'perform'" and "... 'operationDescriptors'"). GREEN after the change.
    - `Sources/Operations/OperationTool.swift`: a new private `resolve(_:) throws(OperationError)` holds the shared resolve step. `call(arguments:)` catches its error and returns `recordCorrective(error.description)`, so the text and the retry cap behavior do not change. A new extension conforms `OperationTool` to `OperationDescribing`. `perform(_:)` does not touch `RetryState`. Internal conversion initializers map `AnyOperation` to `OperationDescriptor`, `ParamMeta` to `OperationParameterDescriptor` (no `short`), and `ParamType` to `OperationParameterType` (exhaustive `switch`, recursive for `.array`).
    - `Tests/OperationsTests/CoreTypesTests.swift`: `FixtureContext`, `FixtureOutput`, `FixtureOperation`, `FailingEncodeOutput`, `FailingEncodeOperation` are now `internal`, so the new test file can use them.
    - `Tests/OperationsTests/OperationDescribingConformanceTests.swift` (new): 13 tests. Descriptor mapping, each `ParamType` case with aliases and allowed values, cast from `any Tool`, `perform` success parity with `call`, `.unknownOperation`, `.missingRequired`, `.decodingFailed`, `.executionFailed`, and two retry-cap tests (refusals of `perform` do not count; a success of `perform` does not reset).
    - `Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift`: new suite `NotesOperationDescribingTests` with 4 tests (five descriptors, `AddNote` and `TagNote` required flags, `tag note` parity of `perform` and `call`).
    - `docs/OPERATIONS_DESIGN_NOTES.md`: new section on why `perform` throws.
    - `Sources/OperationsCLI/AnyOperationTool.swift` has no change. The tests import `FoundationModelsExtras` directly; `Operations` has no typealias for `OperationDescribing` (the card does not ask for one).
    - evidence: `swift build --build-tests` has 0 errors and 0 warnings. `swift test` exit 0: 271 tests in 25 suites passed, plus 125, 44, 34 and 26 in the other test runs. "Public API doc coverage" passed.
    - Not done in this step (by instruction): commit, push, and the SHA comment. That criterion stays unchecked for the orchestrator.
    - next: /review
  timestamp: 2026-09-16T14:36:30.612587+00:00
- actor: claude-code
  id: 01m2nb7fr4jp6ghq3b444ebct6
  text: |-
    ### review — findings
    - evidence: review sha HEAD~2..HEAD, 2 findings (2 confirmed, 0 refuted). Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift:135, Tests/OperationsTests/OperationDescribingConformanceTests.swift:94. Rule: code-hygiene/idioms-swift redundantSwiftTestingSuite.
    - next: Remove each @Suite attribute that has no arguments from the two files. Then run the tests and review again. The push to origin/main and the SHA comment are not findings. The orchestrator does them after this task is done.
  timestamp: 2026-09-16T14:51:41.700094+00:00
- actor: claude-code
  id: 01m2nb820rkrh2tkvve79rggqn
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — OperationTool.swift, OperationDescribingConformanceTests.swift (new), CoreTypesTests.swift, NotesIntegrationTests.swift, OPERATIONS_DESIGN_NOTES.md
    - test: green — swift build 0 warnings; swift test 125 + 34 + 44 + 26 + 271 tests, 0 failed, 5 runs. The test step also made the DoctorRunnerTests timing test deterministic.
    - commit: 684a617, 1c703ee
    - review: findings — Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift:135, Tests/OperationsTests/OperationDescribingConformanceTests.swift:94
  timestamp: 2026-09-16T14:52:00.408820+00:00
- actor: claude-code
  id: 01m2nbgdpmcbqfc87amftm6tb6
  text: |-
    ### implement — changed
    - Fixed finding: `code-hygiene/idioms-swift` redundantSwiftTestingSuite: "Remove redundant @Suite attribute with no arguments."
    - `Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift`: removed all 4 `@Suite` attributes with no arguments (NotesDispatchIntegrationTests, NotesOperationDescribingTests, NotesErrorTests, NotesCLIIntegrationTests).
    - `Tests/OperationsTests/OperationDescribingConformanceTests.swift`: removed the 1 `@Suite` attribute with no arguments (OperationDescribingConformanceTests).
    - Note: the `files` tool with `replace_all` changed only one match. Each match needed a separate edit.
    - evidence: `rg '@Suite'` in the two files finds nothing. `swift build` and `swift test` exit 0, 0 warnings, 271 tests in 25 suites passed.
    - The push criterion stays unchecked for the orchestrator. The task stays in `doing`.
    - next: /review
  timestamp: 2026-09-16T14:56:34.516995+00:00
- actor: claude-code
  id: 01m2nbs0v94n0zmcy58d2m5cfh
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit aad86fe). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. The two prior findings are checked.
    - next: The orchestrator pushes to origin/main after ^rmmv6qv and ^3jpfqa3 are done, and then writes the full commit SHA as a comment on this card.
  timestamp: 2026-09-16T15:01:16.265285+00:00
- actor: claude-code
  id: 01m2nbsa7zbe93qfn104fk86nk
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — NotesIntegrationTests.swift, OperationDescribingConformanceTests.swift (removed 5 @Suite attributes with no arguments)
    - test: green — clean rebuild 0 warnings; swift test 271 tests in 25 suites, 0 failed, 0 skipped
    - commit: aad86fe
    - review: clean — 0 findings; task in done. Next: push main to origin and add the SHA comment.
  timestamp: 2026-09-16T15:01:25.887718+00:00
depends_on:
- 01M2N2AH0WDTKYBC7BMRMMV6QV
position_column: done
position_ordinal: a280
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
- [x] `NotesTool.make()` from `Examples/NotesTool` casts to `any OperationDescribing` and gives five descriptors with the op strings `add note`, `get note`, `list note`, `delete note`, `tag note`.
- [x] The `AddNote` descriptor marks `title` as required, and `body` and `tags` as optional. The `TagNote` descriptor marks `tags` as required.
- [x] `perform` with `{"op": "tag note", "id": "note-1", "tags": ["a"]}` gives the same JSON text as `call` for the same payload.
- [x] `perform` with an unknown op throws `OperationError.unknownOperation`. `call` still returns the corrective text for the same payload.
- [x] `perform` with a missing required field throws `OperationError.missingRequired`, and the retry cap has no effect on a later `call`.
- [x] The full `swift test` passes, including `DocCoverageTests`.
- [ ] The change is pushed to `origin/main`, and a comment on this card names the final revision (the full commit SHA). FoundationModelsMultitool gets Extras by URL and branch `main`, not by path, so `swift package update` cannot get a local commit. The Multitool card pins `Package.resolved` to this revision.

## Tests
- [x] `Tests/OperationsTests/OperationDescribingConformanceTests.swift`: the descriptor mapping for the `CoreTypesTests` fixture operations, each `ParamType` case, and the five `perform` cases above.
- [x] `Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift`: one test that lists the five descriptors of the real notes tool.
- [x] The full `swift test` passes.

## Workflow
- Use `/tdd`. #operation-tools #multitool-ask

## Review Findings (2026-09-16 09:47)

> Scope: `review sha HEAD~2..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `docs/OPERATIONS_DESIGN_NOTES.md` — no validator matches this file

- [x] `Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift:135` `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove redundant @Suite attribute with no arguments.
- [x] `Tests/OperationsTests/OperationDescribingConformanceTests.swift:94` `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove redundant @Suite attribute with no arguments.
