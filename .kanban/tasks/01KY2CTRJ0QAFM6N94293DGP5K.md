---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky2gvvszad5czej99g747ken
  text: |-
    Implemented via TDD. Wrote Tests/FoundationModelsExtrasTests/IgnoreRuleTests.swift first (35 tests, Swift Testing @Suite/@Test), confirmed RED (compile failure: cannot find 'IgnoreRule' in scope), then wrote Sources/FoundationModelsExtras/IgnoreRule.swift.

    Deliberate decisions, documented in the init doc comment:
    1. Lines that strip to an empty pattern (lone `!`, lone `/`, `!/`, whitespace-only) return nil rather than a rule with an empty pattern. Git parses those to a pattern that can never match; nil keeps the invariant that every IgnoreRule has a non-empty pattern.
    2. Trailing-whitespace trim replicates git's trim_trailing_spaces exactly: only spaces are trimmed (never tabs), scanning left-to-right with backslash consuming the next char, so `foo\ ` keeps its escaped space and `foo\<space><space>` trims only the unescaped trailing space.
    3. `\#foo` / `\!pattern` consume the leading escape (pattern `#foo` / `!pattern`, per acceptance criteria); all OTHER backslashes stay intact in the stored pattern (`foo\ ` stores the backslash too) — they are fnmatch escapes resolved at match time.
    4. Escaped trailing slash `foo\/` (odd backslash run before the `/`) is NOT the directory marker: it stays in the pattern and, since a slash remains, the rule is anchored. Unescaped-check uses backslash-run parity.
    5. isAnchored = leading `/` (stripped) OR any `/` remaining after stripping the trailing directory marker — matches git's NODIR check (plain slash search after trailing strip).

    Verification: swift format -i -r Sources Tests (no changes needed), swift build clean, swift test --filter IgnoreRuleTests 35/35, full swift test 150 tests in 13 suites all passed, zero warnings (DocCoverageTests green). Double-check agent review in progress.
  timestamp: 2026-07-21T14:21:50.783742+00:00
- actor: claude-code
  id: 01ky2h2q0by02rf6twtza4drxg
  text: |-
    Double-check agent verdict: REVISE with one low-severity finding — two documented behaviors were implemented correctly but unpinned by tests: (a) an even backslash run before a trailing slash (`foo\\/`) still counts as the directory marker, and (b) git's trim_trailing_spaces early-return on a lone trailing backslash preserves earlier spaces (`foo \` stays intact). Everything else (parse order vs dir.c, trim replication, escape parity, doc coverage, style) checked out.

    Resolution: added both pinning tests — evenBackslashRunBeforeTrailingSlashIsStillDirectoryOnly and trailingLoneBackslashPreservesPrecedingSpaces. Re-ran swift format (no changes) and the full suite: 152 tests in 13 suites, all passed, zero warnings. Acceptance-criteria checkboxes in the description are all marked done. Task left in doing, ready for /review.
  timestamp: 2026-07-21T14:25:35.243437+00:00
position_column: doing
position_ordinal: '80'
title: 'IgnoreRule: parse a single gitignore line into a rule with provenance'
---
## What
Create `Sources/FoundationModelsExtras/IgnoreRule.swift` — a public, `Sendable`, immutable struct representing one parsed line of a gitignore-style file, plus a line parser.

Fields:
- `pattern: String` — the effective match pattern after stripping syntax markers
- `isNegated: Bool` — leading unescaped `!` (re-include)
- `isDirectoryOnly: Bool` — trailing unescaped `/`
- `isAnchored: Bool` — true when the pattern contains a `/` anywhere other than the trailing position (per gitignore: such patterns match relative to the ignore file's directory; slash-free patterns match the basename at any depth)
- `source: String` — display name of the originating file (e.g. `.gitignore`, `.reviewignore`)
- `line: Int` — 1-based line number in that source
- `originalText: String` — the raw line, for explanations

Parsing semantics (git's, from `gitignore(5)` and dir.c):
- A trailing `\r` is stripped before all other processing (CRLF ignore files must behave identically to LF)
- Blank lines and lines whose first non-escaped character is `#` parse to `nil` (no rule)
- `\#` and `\!` escape the comment/negation markers into literal characters
- Unescaped trailing whitespace is stripped; `\ ` preserves a trailing space
- A leading `/` anchors and is stripped from `pattern`; a trailing `/` sets `isDirectoryOnly` and is stripped

Parser entry point: `IgnoreRule.init?(line: String, source: String, lineNumber: Int)` (failable — returns nil for blanks/comments). All public API fully documented (DocCoverageTests fails the build otherwise).

## Acceptance Criteria
- [x] `IgnoreRule` exists, is `public`, `Sendable`, `Equatable`, and fully doc-commented
- [x] Blank lines and `#` comments produce no rule; `\#foo` produces a literal `#foo` pattern
- [x] `!pattern` sets `isNegated`; `\!pattern` matches a literal `!pattern`
- [x] `build/` sets `isDirectoryOnly`; `doc/frob.txt` and `/foo` set `isAnchored`; `*.log` sets neither
- [x] Trailing-space handling: `"foo  "` parses pattern `foo`; `"foo\\ "` preserves the space
- [x] CRLF handling: `"foo\r"` parses pattern `foo`; `"foo\r"` comment/negation/dir-only detection behaves exactly as `"foo"` variants

## Tests
- [x] New `Tests/FoundationModelsExtrasTests/IgnoreRuleTests.swift` (`@Suite`, Swift Testing) covering every bullet above plus edge cases: lone `!`, lone `/`, `!/`, escaped-only lines, CRLF variants of comment/blank/negated lines
- [x] `swift test --filter IgnoreRuleTests` passes; `swift test` stays green (doc coverage included)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.