---
assignees:
- claude-code
position_column: todo
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
- [ ] `IgnoreRule` exists, is `public`, `Sendable`, `Equatable`, and fully doc-commented
- [ ] Blank lines and `#` comments produce no rule; `\#foo` produces a literal `#foo` pattern
- [ ] `!pattern` sets `isNegated`; `\!pattern` matches a literal `!pattern`
- [ ] `build/` sets `isDirectoryOnly`; `doc/frob.txt` and `/foo` set `isAnchored`; `*.log` sets neither
- [ ] Trailing-space handling: `"foo  "` parses pattern `foo`; `"foo\\ "` preserves the space
- [ ] CRLF handling: `"foo\r"` parses pattern `foo`; `"foo\r"` comment/negation/dir-only detection behaves exactly as `"foo"` variants

## Tests
- [ ] New `Tests/FoundationModelsExtrasTests/IgnoreRuleTests.swift` (`@Suite`, Swift Testing) covering every bullet above plus edge cases: lone `!`, lone `/`, `!/`, escaped-only lines, CRLF variants of comment/blank/negated lines
- [ ] `swift test --filter IgnoreRuleTests` passes; `swift test` stays green (doc coverage included)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.