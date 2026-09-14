---
comments:
- actor: claude-code
  id: 01m2fxj76413w3g2dcfwc2k78m
  text: |-
    Research:
    - `OperationError` conforms to `Equatable` with synthesis. A case with an `any Error` value stops the synthesis. A hand-written `==` is necessary, because tests use `error == .decodingFailed` and `error == .executionFailed`.
    - Plan: `case executionFailed(cause: any Error)`. `Error` is `Sendable` in Swift 6, so the enum stays `Sendable`. The `==` compares the type name and the text of the two causes.
    - Callers of `.executionFailed`: `AnyOperation.run` (the one producer), `CoreTypesTests` (two tests), and `Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift` (three tests with `error == .executionFailed`). `OperationTool.call` does not catch the case; it goes to the host as the thrown error. `NotesError.swift` doc text names the case and stays correct.
    - Examples/NotesTool is a target of the root Package.swift, so the root `swift test` runs its tests.
  timestamp: 2026-09-14T12:16:41.156113+00:00
- actor: claude-code
  id: 01m2fxpwk3n0es4wb20264th3j
  text: |-
    Implementation done (TDD).
    - RED: the new and changed tests did not compile, with `enum case 'executionFailed' has no associated values`.
    - GREEN: `OperationError.executionFailed(cause: any Error)`. The description is `This operation failed while executing. Cause: <text of cause>`. The first sentence did not change. `AnyOperation.run` passes the caught `error`. `Equatable` is now hand-written, because `any Error` stops the synthesis. Two `.executionFailed` values are equal when the causes have the same dynamic type and the same `String(describing:)` text.
    - Tests: `CoreTypesTests` (cause in equality, cause in description through `AnyOperation.run`, description text, equality for each case), `OperationToolTests.executionFailedFromOperationExecuteThrowsAnErrorThatNamesTheCause` (the path of a tool call), and the three NotesTool tests now compare with `.executionFailed(cause: NotesError.notFound(id: "missing"))`.
    - Doc comments updated on `AnyOperation.run` and `OperationTool.call`.
    - `swift test`: exit 0. Swift Testing runs: 102, 34, 44, 22, 264 tests, all passed. No warnings in the build.
  timestamp: 2026-09-14T12:19:14.147730+00:00
- actor: claude-code
  id: 01m2fxpyznp10hb2d9qpbdyt3q
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/Operations/OperationError.swift, Sources/Operations/AnyOperation.swift, Sources/Operations/OperationTool.swift, Tests/OperationsTests/CoreTypesTests.swift, Tests/OperationsTests/OperationToolTests.swift, Examples/NotesTool/Tests/NotesToolTests/NotesIntegrationTests.swift; `swift test` exit 0, 0 failures, 0 warnings
    - next: review
  timestamp: 2026-09-14T12:19:16.597978+00:00
- actor: claude-code
  id: 01m2fxtde9t327mpwax2z403hn
  text: |-
    ### test — green
    - evidence: `swift test` — 264 tests, 24 suites, 0 fail, 0 skip. `swift build` — clean, 0 warnings.
    - next: ready for review.
  timestamp: 2026-09-14T12:21:09.705010+00:00
- actor: claude-code
  id: 01m2fy20583cpxzk4n5x2ns7g2
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD — 4 findings (4 confirmed, 1 refuted) — Sources/Operations/OperationError.swift:48, Sources/Operations/OperationError.swift:50, Sources/Operations/OperationError.swift:54, Sources/Operations/OperationError.swift:86
    - next: implement — put `let` before each bound variable in each `case` pattern in Sources/Operations/OperationError.swift, then test, commit, and review again.
  timestamp: 2026-09-14T12:25:18.248538+00:00
- actor: claude-code
  id: 01m2fy2bhq3gawm8a387k4q967
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files
    - test: green — swift test, 264 passed, 0 failed, 0 skipped
    - commit: acb8c17
    - review: findings — Sources/Operations/OperationError.swift:48, Sources/Operations/OperationError.swift:50, Sources/Operations/OperationError.swift:54, Sources/Operations/OperationError.swift:86
  timestamp: 2026-09-14T12:25:29.911816+00:00
- actor: claude-code
  id: 01m2fy4gbemy60chd7wt5t5943
  text: |-
    Review findings fixed.
    - `Sources/Operations/OperationError.swift`: all six `case let` patterns now put `let` before each bound variable. This includes the four reported patterns and the two that were not reported (`.unknownOperation(let valid)` and `.missingRequired(let names)` in `description`). The file has no `case let` now.
    - The other files of commit acb8c17 (`AnyOperation.swift`, `OperationTool.swift`, `CoreTypesTests.swift`, `OperationToolTests.swift`, `NotesIntegrationTests.swift`) have no `case let` patterns. No change was necessary there.
    - Other `case let` patterns are in files outside this change (`SchemaFusion.swift`, `OperationResolver.swift`, `CLIRegistryBuilder.swift`, `OperationOutcome.swift`, `ProcessRegistryTests.swift`). This task did not change them.
    - `swift test`: exit 0, 264 tests in 24 suites passed, 0 failures, 0 warnings.
  timestamp: 2026-09-14T12:26:40.366223+00:00
- actor: claude-code
  id: 01m2fy4hpdnsaa8qvkeqvttqc8
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/Operations/OperationError.swift; `swift test` exit 0, 264 passed, 0 failed, 0 warnings
    - next: test, commit, review
  timestamp: 2026-09-14T12:26:41.741768+00:00
- actor: claude-code
  id: 01m2fy8jrtxn3nmn8r37n4q8db
  text: |-
    ### test — green
    - evidence: `swift build` — build complete, 0 warnings. `swift test` — 264 tests passed, 0 failed, 0 skipped, in 24 suites.
    - check: `swiftlint` reported 0 issues.
    - note: `swiftformat --lint` found format issues in 110 of 125 files across the repo. This is old debt. It is not part of this diff. It is out of scope for this test step.
    - next: send the task to review.
  timestamp: 2026-09-14T12:28:53.914068+00:00
position_column: doing
position_ordinal: '80'
title: A thrown operation loses its cause, so every failure reads 'This operation failed while executing.'
---
## The problem

An operation that throws gives one sentence, and the sentence names no cause:

```
This operation failed while executing.
```

The cause is caught, and then it is thrown away:

```swift
// Sources/Operations/AnyOperation.swift:78-82
do {
    output = try await operation.execute(in: context)
} catch {
    throw OperationError.executionFailed
}
```

`OperationError.executionFailed` holds no associated value
(`Sources/Operations/OperationError.swift:27`), so the `error` of the catch
cannot travel with it. The text is at
`Sources/Operations/OperationError.swift:51-52`. `OperationTool.call` catches
`.decodingFailed` only, and it gives this one to the host
(`OperationTool.swift:183-189`).

## What it cost

In the SWE-bench run of `FoundationModelsACPAgent` on 2026-09-13, the `skills`
tool failed on three of 16 instances. Each instance lost its whole turn and
made no patch. The transcript of each one holds this sentence and nothing
else.

The true cause was four packages away: a search over an empty catalog asked
the model a question, the model answered with prose, and a JSON decode threw
at `FoundationModelsRanker/Sources/FoundationModelsRanker/Selection/AgentSession.swift:111`.
To find that, a person had to read the source of five packages. The message
gave no help at all.

The same sentence will come back for the next failure on this path, whatever
the next failure is.

## The work

Give the case a cause, and put the cause in the text.

- `Sources/Operations/OperationError.swift:27` — give `executionFailed` an
  associated value for the error that was caught.
- `Sources/Operations/OperationError.swift:51-52` — put that cause in the
  description, after the sentence.
- `Sources/Operations/AnyOperation.swift:80-82` — pass the caught `error` to
  the case.

Keep the first sentence. A reader of a log knows it, and a test can match on
it. Add the cause after it.

## When it is complete

- An operation that throws gives a message that names the underlying error.
- A test proves that the cause of a thrown operation reaches the text of
  `OperationError`.
- A person who reads the transcript of a failed tool call can say what went
  wrong, with no need to read the source of another package.

## Review Findings (2026-09-14 07:21)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/Operations/OperationError.swift:48` `code-hygiene/idioms-swift` — UseLetInEveryBoundCaseVariable: move this 'let' keyword inside the 'case' pattern, before each of the bound variables.
- [x] `Sources/Operations/OperationError.swift:50` `code-hygiene/idioms-swift` — UseLetInEveryBoundCaseVariable: move this 'let' keyword inside the 'case' pattern, before each of the bound variables.
- [x] `Sources/Operations/OperationError.swift:54` `code-hygiene/idioms-swift` — UseLetInEveryBoundCaseVariable: move this 'let' keyword inside the 'case' pattern, before each of the bound variables.
- [x] `Sources/Operations/OperationError.swift:86` `code-hygiene/idioms-swift` — UseLetInEveryBoundCaseVariable: move this 'let' keyword inside the 'case' pattern, before each of the bound variables.
