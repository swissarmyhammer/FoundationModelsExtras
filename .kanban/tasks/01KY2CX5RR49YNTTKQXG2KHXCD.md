---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky2s6qv5k4f6k6mhna6fntye
  text: |-
    Implemented TDD-first: added 4 failing integration tests to ExtrasDemoIntegrationTests.swift (single-file, combined-file override, trailing-slash directory probe, unreadable-file error), confirmed red (Unknown option '--file'), then added Examples/ExtrasDemo/Sources/extras-demo/IgnoreCommand.swift + registered it in main.swift, plus fixtures Examples/ExtrasDemo/Fixtures/ignore/.gitignore (`*.log`, `build/`) and review-ignore (`!src/keep.log`, demonstrating override-on-combine). All 4 new tests pass; full `swift test` green (193 tests, 18 suites).

    Note: accidentally ran `swift format -i -r Sources Tests Examples` (should have been Sources Tests only per project facts) which reformatted several unrelated existing Examples files from 4-space to 2-space indent. Reverted those via `git checkout --` and manually restored main.swift to the original 4-space style with just my intended diff, so the final diff is minimal and scoped to this task.
  timestamp: 2026-07-21T16:47:35.781229+00:00
depends_on:
- 01KY2CWAEKSXR967RZ8A1F6CGQ
position_column: doing
position_ordinal: '80'
title: extras-demo `ignore` subcommand + integration test
---
## What
Surface the feature through the repo's living-contract-test convention (the `extras-demo` executable). Documentation (README/plan.md) is a separate follow-on task.

1. New subcommand in `Examples/ExtrasDemo/Sources/extras-demo` (own file, e.g. `IgnoreCommand.swift`, following the existing one-subcommand-per-pillar layout): `extras-demo ignore --file <ignore-file> [--file <ignore-file> ...] <path> [<path> ...]`
   - Each `--file` loads an `IgnoreProcessor`; multiple files are combined left-to-right with `+`
   - Tested paths use the trailing-slash convention for directories (`build/` probes as a directory), passed straight through to `evaluate` — document this in the subcommand's `--help` abstract
   - For each tested path, print one line: the path, `ignored` or `included`, and the verdict's why (the `IgnoreVerdict` description — deciding source:line and pattern, or "no rule matched")
   - Exit code 0; nonzero with a clear message when an ignore file can't be read
2. Fixture ignore files under the demo's existing fixture tree (a `.gitignore`-style file plus a second e.g. `review-ignore` file demonstrating override-on-combine, and at least one directory-only rule exercised via a trailing-slash probe)
3. Integration test in `Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift` following the existing subprocess conventions: run the subcommand against the fixtures, assert on stdout verdict lines including the why text, the combined-override case, and a trailing-slash directory probe

## Acceptance Criteria
- [ ] `swift run extras-demo ignore --file <fixture> a.log src/keep.log build/` prints per-path verdicts with source:line reasons, honoring the trailing-slash directory probe
- [ ] Two `--file` flags demonstrate `+` combination with the later file overriding
- [ ] Unreadable ignore file exits nonzero with the path in the message

## Tests
- [ ] Integration test in `ExtrasDemoIntegrationTests.swift` asserting stdout for single-file, combined-file, directory-probe, and error cases
- [ ] Full `swift test` green (builds the demo via the existing testTarget dependency)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.