---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2x8grvcp3nvs95vjsjxsez3
  text: |-
    Picked up. Research:
    - `ProcessRunner` is in `Sources/FoundationModelsExtras/ProcessRunner.swift`, committed as 8585d56. The CHANGELOG `Unreleased` section records the API and the cause (the Skills package carried a runner of its own, with no link to `ProcessRegistry`).
    - The README has no `ProcessRunner` section. The `IgnoreProcessor` section is the shape to follow: one paragraph, one code block, and one sentence that names the mirror test and the `swift test --filter` command.
    - The mirror test precedent is `readmeGitignoreAndReviewignoreCombinationExample` in `Tests/FoundationModelsExtrasTests/IgnoreProcessorTests.swift`, under a `// MARK: - README example` heading at the end of the suite.
    - `plan.md` §5 holds the `ProcessRegistry` parenthetical in the "Scope fights its way in" bullet. The `ProcessRunner` note goes beside it.
    - `Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift` gives each test a private `ProcessRegistry()`, never `.global`, because the suites of the package run at the same time in one process. The README example leaves `registry` at its default; the mirror test states that one difference in its doc comment.
    - The review rules for `.swift` files: every numeric literal outside a declaration gets a name, no `guard` in a test, `#require` for an unwrap, no copied blocks. The `.md` files match no validator.
  timestamp: 2026-09-19T16:38:15.660815+00:00
- actor: claude-code
  id: 01m2x8kacwyntkebxpf5s1msch
  text: |-
    Implementation landed. TDD record:
    - RED: wrote `readmeExitCodeAndMergedOutputExample` first, at the end of `ProcessRunnerTests`, under a `// MARK: - README example` heading. `swift test --filter ProcessRunnerTests` ran 15 tests, and the new test passed at once. That is the expected result for this card: the card asks for no production code, and the test pins the behavior `ProcessRunner` already has. The production change that makes this test fail is a change to the `ProcessRunner` contract, for example stderr no longer merged, or the exit code decoded in a different way. The `IgnoreProcessor` mirror has the same nature.
    - GREEN: added the `## Running a process: ProcessRunner` section to `README.md` between the `Doctorable` section and `Install`, with the same call and the same script as the test. Added the `ProcessRunner` parenthetical to `plan.md` §5 beside the `ProcessRegistry` one, dated 2026-09-19 (the date of commit 8585d56).
    - The README example leaves `registry` at its default. The test passes a private `ProcessRegistry()`. The README and the test doc comment both state that one difference and its reason.
    - The README sentence about `ProcessRegistry.global` and the `atexit` sweep was checked against `Sources/FoundationModelsExtras/ProcessRegistry.swift`.
    - `swift test`: 364 tests in 29 suites passed, zero failures, zero compiler warnings. `swift format lint --strict` on the test file: exit 0.

    ### implement — changed
    - evidence: 3 files — README.md, plan.md, Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift; `swift test` 364 passed in 29 suites, 0 failures, 0 warnings
    - next: /review
  timestamp: 2026-09-19T16:39:39.164242+00:00
- actor: claude-code
  id: 01m2x8pf9qadcbxcapj951nq8k
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (after `swift package clean`) — build complete, 0 warnings; `swift test` — 364 tests passed, 0 failed, 0 skipped, in 29 suites
    - next: ready for review
  timestamp: 2026-09-19T16:41:22.487058+00:00
position_column: doing
position_ordinal: '80'
title: Document ProcessRunner in README and note the plan.md scope extension
---
## What

`ProcessRunner` landed in `Sources/FoundationModelsExtras/ProcessRunner.swift` (card ^86z4bmc). The CHANGELOG records the public API. The README and `plan.md` do not name it yet.

1. Add a README section for `ProcessRunner`, in the shape of the `IgnoreProcessor` and `Doctorable` sections: one short paragraph on what it does (process group, merged bounded output, timeout with the group kill, the `ProcessRegistry` ledger), and one runnable example.
2. Add a note to `plan.md` §5 beside the `ProcessRegistry` note: `ProcessRunner` fought its way in with the same reason (the Skills package carried its own runner with no link to the registry).

## Acceptance Criteria

- [x] README holds a `ProcessRunner` section with a runnable example.
- [x] `plan.md` §5 names `ProcessRunner` beside `ProcessRegistry`.
- [x] The example in the README is mirrored by a test, as the `IgnoreProcessor` example is.

#docs #process-safety