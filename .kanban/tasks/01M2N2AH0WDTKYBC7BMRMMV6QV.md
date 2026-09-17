---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2n8f72y61w23108hsxeqc3r
  text: |-
    Research: `ForkableTool.swift` is the pattern (a protocol on `Tool` with no associated types). The core test target uses `@testable import FoundationModelsExtras`. The new test file uses a plain `import FoundationModelsExtras` (plus `FoundationModels` and `Testing`) to show that a conformer needs no `Operations` import. The fixture reads the op with `GeneratedContent.value(String.self, forProperty: "op")`.

    TDD: the test file failed to compile first (the types did not exist). Then the source file made all 6 tests pass. The `required: Bool` field keeps the name from the card, not `isRequired`.

    The push criterion stays unchecked. The orchestrator commits and pushes one time, after ^rmmv6qv and ^3jpfqa3 are done.
  timestamp: 2026-09-16T14:03:29.246539+00:00
- actor: claude-code
  id: 01m2n8f8wpr25ge5g612c7srmq
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsExtras/OperationEvents/OperationDescribing.swift (new), Tests/FoundationModelsExtrasTests/OperationDescribingTests.swift (new). `swift build`: 0 warnings, 0 errors. `swift test --filter OperationDescribingTests`: 6 tests pass. Full `swift test`: 271 + 111 + 44 + 34 + 22 tests pass, 0 failures.
    - next: review. The orchestrator commits, pushes after ^3jpfqa3, and adds the SHA comment.
  timestamp: 2026-09-16T14:03:31.094609+00:00
- actor: claude-code
  id: 01m2n8zk72dwxw2snnrn7dh337
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 1a62f5f): 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsExtrasTests/OperationDescribingTests.swift:103 (code-hygiene/idioms-swift, redundantSwiftTestingSuite).
    - next: Remove each @Suite attribute that has no arguments from OperationDescribingTests.swift. Then commit and review again. The push to origin/main is not a review finding. The orchestrator does the push after ^rmmv6qv and ^3jpfqa3 are done.
  timestamp: 2026-09-16T14:12:25.954182+00:00
- actor: claude-code
  id: 01m2n90314nkw0ssggtzypvngj
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — OperationDescribing.swift, OperationDescribingTests.swift
    - test: green — swift build 0 warnings; swift test 271 tests in 25 suites, 0 failed
    - commit: 1a62f5f
    - review: findings — Tests/FoundationModelsExtrasTests/OperationDescribingTests.swift:103
  timestamp: 2026-09-16T14:12:42.148265+00:00
- actor: claude-code
  id: 01m2n97gw42y24h9cjaz7gv8h9
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsExtrasTests/OperationDescribingTests.swift. The file had one `@Suite` with no arguments. It is removed. `swift build` passes. `swift test`: 271 tests in 25 suites pass, 0 warnings.
    - next: review. The push criterion stays open for the orchestrator.
  timestamp: 2026-09-16T14:16:45.700238+00:00
- actor: claude-code
  id: 01m2n9jy9r4y3zdsy7t4859wy3
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit de59fef) found 0 findings (7 validators attempted, 0 failed). The prior finding at `Tests/FoundationModelsExtrasTests/OperationDescribingTests.swift:103` is checked and fixed.
    - next: The orchestrator pushes to origin/main one time after ^rmmv6qv and ^3jpfqa3 are done. Then it writes the full commit SHA as a comment on this card. The user decided this, so the push criterion does not keep this task out of done.
  timestamp: 2026-09-16T14:22:59.896658+00:00
- actor: claude-code
  id: 01m2n9k9pc6z427xccf236b566
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — OperationDescribingTests.swift (removed the @Suite with no arguments)
    - test: green — swift build 0 warnings; swift test 271 tests in 25 suites, 0 failed
    - commit: de59fef
    - review: clean — 0 findings; task in done. The push to origin/main and the SHA comment come after ^3jpfqa3 is done.
  timestamp: 2026-09-16T14:23:11.564128+00:00
- actor: claude-code
  id: 01m2nbsv08vnxyf5d9tk4vqha5
  text: |-
    ### push — done
    - The change is on origin/main. Final revision: c98ae6ba956f82e0d75bcb7583b28e5c88304d23
    - This card's commits: 1a62f5f, de59fef. The revision also has ^3jpfqa3 (684a617, 1c703ee, aad86fe).
    - FoundationModelsMultitool can pin Package.resolved to this revision.
  timestamp: 2026-09-16T15:01:43.048001+00:00
position_column: done
position_ordinal: a180
title: Add the OperationDescribing protocol and its descriptor types
---
## What
Create `Sources/FoundationModelsExtras/OperationEvents/OperationDescribing.swift`. Use the pattern of `Sources/FoundationModelsExtras/OperationEvents/ForkableTool.swift`: no associated types, so that `tool as? any OperationDescribing` succeeds on an `any Tool`. The protocol must be in the core `FoundationModelsExtras` module, not in `Operations`, because FoundationModelsMultitool links only the core product.

Add these declarations:
- `public protocol OperationDescribing: Tool` with:
  - `var operationDescriptors: [OperationDescriptor] { get }`
  - `func perform(_ arguments: GeneratedContent) async throws -> String`. This is a dispatch that throws. The payload has the same shape as a model call: an `op` key and the fields of one operation. A refusal (unknown op, missing required field, decode failure) is thrown, not returned as text. The doc comment must state this difference from `Tool.call`.
- `public struct OperationDescriptor: Sendable, Equatable` with `verb`, `noun`, `opString`, `description`, `parameters: [OperationParameterDescriptor]`, and a public memberwise `init`.
- `public struct OperationParameterDescriptor: Sendable, Equatable` with `name`, `type: OperationParameterType`, `required: Bool`, `description`, `aliases: [String]`, `allowedValues: [String]?`, and a public memberwise `init`.
- `public indirect enum OperationParameterType: Sendable, Equatable` with the cases `string`, `integer`, `number`, `boolean`, `array(of: OperationParameterType)`.

These are new type-erased value types. Do not move `ParamMeta` or `ParamType` out of `Operations`. Every public declaration must have a doc comment.

Source: request from the FoundationModelsMultitool planning session. Multitool will mount an `OperationTool<Context>` as one verb per operation in code mode. A host that holds `any Tool` cannot see `OperationTool.operations`, because of the generic `Context`.

## Acceptance Criteria
- [x] `swift build` passes.
- [x] A test type that conforms to `OperationDescribing` compiles with only `import FoundationModelsExtras`.
- [x] `(tool as any Tool) as? any OperationDescribing` returns the tool for a conforming type, and `nil` for a plain `Tool`.
- [x] The doc comment of `perform(_:)` states that a refusal is thrown, and that `call(arguments:)` keeps its rule to return, not throw.
- [ ] The change is pushed to `origin/main`, and a comment on this card names the final revision (the full commit SHA). FoundationModelsMultitool gets Extras by URL and branch `main`, not by path, so `swift package update` cannot get a local commit. The Multitool card pins `Package.resolved` to this revision.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/OperationDescribingTests.swift`: a hand-conformed fixture tool; the cast test; descriptor equality; `perform` throws for a bad op.
- [x] `swift test --filter OperationDescribingTests` passes.

## Workflow
- Use `/tdd`. #operation-tools #multitool-ask

## Review Findings (2026-09-16 09:05)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsExtrasTests/OperationDescribingTests.swift:103` `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove redundant @Suite attribute with no arguments.
