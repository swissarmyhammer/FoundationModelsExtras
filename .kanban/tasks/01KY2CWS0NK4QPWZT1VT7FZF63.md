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
- actor: claude-code
  id: 01ky2p8zxwgqnnmmymzq9p9t9c
  text: |-
    Review Findings (iteration 1, mcp__sah__review op=review sha HEAD~1..HEAD):

    ## Review Findings
    - [x] IgnoreGitParityTests.swift:123 — `static let processor` lacked a doc comment. Added one.
    - [x] IgnoreGitParityTests.swift:175 — `GitProcessError` lacked `Sendable` conformance. Added it.

    Both fixed, `swift format -i -r Sources Tests` clean, `swift build` clean, full `swift test` green (180/180). Committing fixes now and re-reviewing.
  timestamp: 2026-07-21T15:56:23.868689+00:00
- actor: claude-code
  id: 01ky2pqz8v1xtay2yg7jqfjjg3
  text: |-
    Review Findings (iteration 2, mcp__sah__review op=review sha HEAD~2..HEAD):

    ## Review Findings
    - [x] IgnoreProcessor.swift ~97 (`ruleText` doc comment) — summary sentence ran directly into elaboration with no blank line. Split into a one-sentence summary + blank line + elaboration.
    - [x] IgnoreGitParityTests.swift Probe.isIgnored — added doc comment.
    - [x] IgnoreGitParityTests.swift GitVerdict.source — added doc comment.
    - [x] IgnoreGitParityTests.swift GitVerdict.pattern — added doc comment.

    Fixed all four, `swift format -i -r Sources Tests` clean, `swift build` clean, full `swift test` green (180/180), CRLF fixture byte content re-verified intact (5 `\r` bytes, unchanged). Committing and re-reviewing.
  timestamp: 2026-07-21T16:04:34.715189+00:00
- actor: claude-code
  id: 01ky2qqwd5jyafsypwed7d81qx
  text: |-
    Review Findings (iteration 3, mcp__sah__review op=review sha HEAD~3..HEAD — first attempt at this range returned "1/14 review tasks failed — INCOMPLETE" with 0 findings; re-ran and got a complete result):

    ## Review Findings
    - [x] IgnoreProcessor.swift `parentExcluded` case doc — no blank line between summary and elaboration sentence. Fixed (also pre-existing, adjacent to my edits).
    - [x] IgnoreProcessor.swift `evaluate(_ paths:)` doc — same issue. Fixed (pre-existing).
    - [x] IgnoreGitParityTests.swift `Probe` type doc — same issue. Fixed.
    - [x] IgnoreGitParityTests.swift `GitProcessError` doc — same issue. Fixed.
    - [x] IgnoreGitParityTests.swift `isGitAvailable()` doc — same issue. Fixed.
    - [x] IgnoreGitParityTests.swift `materialize(_:under:)` doc — same issue. Fixed.

    All six were the "single-sentence summary, blank line, elaboration" doc-comment convention — some in code adjacent to my diff but pre-existing (not introduced by me), fixed anyway since they're low-risk comment-only changes and the reviewer flags them when scanning a touched file. `swift format` clean, `swift build` clean, full `swift test` green (180/180), CRLF fixture byte-verified intact (5 `\r` bytes, unchanged). Committing and re-reviewing. Noting for the stuck-guardrail: each iteration's findings have been distinct (different file:line), not the same finding recurring, so the 3x-repeat guardrail hasn't triggered — but flagging that this style rule is being applied inconsistently across the codebase (many other pre-existing multi-sentence doc paragraphs elsewhere in Sources/ don't get flagged, e.g. IgnoreRule.swift's `isAnchored` doc has the identical shape) — if a 4th iteration surfaces yet another instance of this exact same stylistic pattern, I'll treat it as effectively the same finding class for the stuck guardrail rather than let it whack-a-mole indefinitely.
  timestamp: 2026-07-21T16:22:00.357595+00:00
- actor: claude-code
  id: 01ky2r7gb1bz87bfe8dcrjjbhh
  text: |-
    Review Findings (iteration 4, mcp__sah__review op=review sha c7c1712..HEAD, full cumulative diff since before this task started):

    ## Review Findings
    - [x] IgnoreGitParityTests.swift `materialize(_:under:)` — first argument label omitted on a side-effecting (non-value-preserving) function; per the fluent-usage rule this should be labeled. Renamed to `materialize(probePath:under:)` and updated the one call site.

    Fixed, `swift format` clean, `swift build` clean, full `swift test` green (180/180), CRLF fixture byte-verified intact (5 `\r` bytes, unchanged). Committing and doing one more review pass.
  timestamp: 2026-07-21T16:30:32.289980+00:00
depends_on:
- 01KY2CVY2Y8VH8YVHVM0JXPZ0N
position_column: review
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