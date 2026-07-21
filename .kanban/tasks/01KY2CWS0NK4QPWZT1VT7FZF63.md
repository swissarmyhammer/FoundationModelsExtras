---
assignees:
- claude-code
depends_on:
- 01KY2CVY2Y8VH8YVHVM0JXPZ0N
position_column: todo
position_ordinal: '8480'
title: 'Git-parity corpus test: verdicts match `git check-ignore -v`'
---
## What
Add a correctness anchor proving `IgnoreProcessor` agrees with real git. Create `Tests/FoundationModelsExtrasTests/IgnoreGitParityTests.swift`:

- A checked-in fixture ignore file at `Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/gitignore.txt` exercising the full pattern surface (comments, escapes, CRLF lines, negation, anchoring, dir-only, `*`, `?`, `[!...]`/`[^...]` classes, named POSIX classes, all three `**` forms, parent-exclusion setups) plus a probe list of ~40 relative paths with expected ignored/included outcomes. Directory probes are marked with the trailing-slash convention (`build/`) — the same convention `evaluate` and `git check-ignore` use — which also tells the parity harness to `mkdir` rather than touch a file when materializing
- Test 1 (always runs): table-driven — `IgnoreProcessor` verdicts over the probe list match the checked-in expectations
- Test 2 (git parity, runs when a `git` binary is available): materialize the fixture in a temp dir as a real repo (`git init`, write the corpus as `.gitignore`, create probe files/dirs per the trailing-slash markers), run `git check-ignore --verbose --non-matching` over the probe list via `Process`, and assert our verdict (ignored/included AND the matching source:line where git reports one) agrees for every probe. Invocation details: feed probes via `--stdin`; treat exit codes 0 AND 1 as success (1 just means no probe was ignored), 128 as failure; `--non-matching` requires `--verbose`. Skip cleanly with Swift Testing's conditional-skip if `git` is not on PATH — never fail for a missing tool

This task depends only on the core `IgnoreProcessor` so parity feedback on the semantics engine lands as early as possible; git-parity for the `+` operator lives in the `+` task itself. Make the git subprocess + repo-materialization helpers reusable (internal test helpers in this file), since the `+` task's parity test builds on the same plumbing when both exist.

Follow the existing `ExtrasDemoIntegrationTests` subprocess-launching conventions and the `Fixtures`-resource declaration pattern already in `Package.swift` (add the new fixture dir to the testTarget resources if enumeration warnings appear).

## Acceptance Criteria
- [ ] Probe corpus covers every semantics bullet from the IgnoreRule/Wildmatch/IgnoreProcessor tasks at least once, with at least 3 directory probes using the trailing-slash marker
- [ ] Table-driven expectations pass without git installed
- [ ] With git installed, every probe's ignored/included status and deciding pattern line agree with `git check-ignore --verbose`; any divergence fails with a message naming the probe, our verdict, and git's
- [ ] No network, no writes outside the temp dir

## Tests
- [ ] This task IS tests: `swift test --filter IgnoreGitParityTests` passes locally (git present) and with git absent (skips parity, runs table)
- [ ] Full `swift test` stays green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass (here: write the corpus + expectations first; fix any `IgnoreProcessor` divergences the parity run exposes).