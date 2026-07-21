---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky2nvs26t32bx8xgbn7mh7mf
  text: |-
    Implemented in one pass (TDD-ish, verified against real git before committing to expectations):

    - Fixture: `Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/gitignore.txt` — 40-probe corpus covering comments, escapes (`\#`, `\!`, escaped trailing space), CRLF lines (lines 14-16 and 47-48 deliberately CRLF-terminated), negation, anchoring, dir-only rules, `*`/`?`, `[!...]`/`[^...]` classes, a named POSIX class, all three `**` forms, and parent-exclusion (including the "negating the ancestor lifts exclusion" case).
    - `Tests/FoundationModelsExtrasTests/IgnoreGitParityTests.swift`: Test 1 (table-driven, always runs) + Test 2 (git-gated via `.enabled(if: GitParityHarness.isGitAvailable())`), plus a reusable (internal, not private) `GitParityHarness` enum with `isGitAvailable()`, `materializeRepo(gitignoreContents:probePaths:)`, and `runCheckIgnore(probePaths:repoURL:)` for a later task to reuse.

    Two real bugs/gotchas found and worked around/fixed while authoring the corpus against actual `git check-ignore -v` output (git 2.55.0):

    1. **Git CLI bug, not ours**: a `.gitignore` file with a CRLF-terminated *blank* line (anywhere in the file, not just at EOF) makes `git check-ignore -v` misattribute every directory probe with no real match to that blank line's line number, as if it were a catch-all. Confirmed via minimal repro (`foo\r\n\r\n` + probing an unrelated `bar/`). Worked around by only CRLF-terminating non-blank lines in the fixture (blank-line separators stay LF) — re-verified full 40-probe parity is byte-identical to the pure-LF baseline after this change.
    2. **Real bug in our code, fixed**: `IgnoreProcessor.init(string:source:)` used `string.split(separator: "\n")` (`Character`-based). Swift's `Character` treats a CRLF pair as a single extended grapheme cluster, so that split silently fails to break at CRLF line boundaries, merging lines and corrupting every subsequent line number in a multi-line CRLF ignore file. Fixed by splitting on `string.unicodeScalars` instead (scalars aren't grapheme-clustered, so `\r`/`\n` are always distinct). This is a real, previously-undetected bug in the already-"done" `IgnoreProcessor.swift` — none of the existing `IgnoreProcessorTests` exercised a multi-line CRLF file through the `string:` initializer, only single-line CRLF stripping via `IgnoreRule` directly.

    Also dropped two probe candidates that would have baked in git CLI quirks rather than real gitignore semantics: a bare-directory probe against a trailing-`**` rule (`logs/`), and a bare-directory probe against a *negated* dir-only ancestor rule (`lifted/`) — both showed asymmetric/quirky `git check-ignore` behavior specific to trailing-slash-vs-not queries that isn't reflective of general gitignore matching semantics, and neither is required to hit every semantics bullet (both are covered elsewhere in the corpus via non-directory probes).

    Result: `swift test --filter IgnoreGitParityTests` green (40/40 table cases + git-parity test), full `swift test` green (180/180). `swift build` and `swift format -i -r Sources Tests` clean.
  timestamp: 2026-07-21T15:49:10.854674+00:00
depends_on:
- 01KY2CVY2Y8VH8YVHVM0JXPZ0N
position_column: doing
position_ordinal: '80'
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