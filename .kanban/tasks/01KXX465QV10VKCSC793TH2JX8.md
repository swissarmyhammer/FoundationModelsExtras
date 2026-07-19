---
comments:
- actor: claude-code
  id: 01kxx8mdb03a58rmhkv1h6z6rk
  text: |-
    Implemented via TDD:
    - Sources/FoundationModelsExtras/FrontmatterDocument.swift: `FrontmatterDocument.split(_:)` — purely textual triple-hyphen fence-line recognition, no YAML dependency. Uses a Character-level line scanner (Swift already fuses CRLF into one grapheme cluster, so no special-casing needed) to find the opening/closing fence lines. Unterminated opening fence falls back to whole-text-as-body.
    - Sources/FoundationModelsExtras/TemplateContext.swift: `TemplateValue` (string/number/bool/array/dict, recursive, Sendable) and `TemplateContext` (Sendable, `init()`, `set(_:_:)`) plus an internal `stencilDictionary()` bridge to `[String: Any]` for the future `TemplateEngine` task.
    - Tests/FoundationModelsExtrasTests/FrontmatterDocumentTests.swift and TemplateContextTests.swift cover all acceptance-criteria edge cases (frontmatter+body split, no-frontmatter, empty frontmatter block, a later triple-hyphen line in the body not treated as a fence, unterminated fence, CRLF).

    Wrote failing tests first (compile-red because the types didn't exist), then implemented — all 11 tests green, `swift build` clean with no warnings.
  timestamp: 2026-07-19T13:21:45.824589+00:00
- actor: claude-code
  id: 01kxx8qs86hyjk0f7ba43vzmqx
  text: |-
    really-done: adversarial double-check agent returned PASS. Verified independently: signatures match plan.md §4 exactly; both types Sendable and Foundation-only (no Stencil import, `stencilDictionary()` correctly non-public); CRLF handling reasoning confirmed (Swift Character grapheme clustering treats CRLF as one Character per UAX #29); all public declarations documented including all 5 `TemplateValue` cases; `swift test` re-run independently, 11/11 pass.

    Noted (not fixed, logged per really-done contract): the opening/closing fence match requires the line to be exactly a triple-hyphen with no trailing whitespace (e.g. a triple-hyphen followed by two spaces is not recognized as a fence, and falls through to no-frontmatter). This is outside the task's explicit edge cases and acceptance criteria, and no test exercises it either way — leaving as-is rather than guessing at unspecified behavior. Flagging for whoever reviews in case a future task wants tolerant whitespace handling.

    Build/test: `swift build` clean (no warnings), `swift test` 11/11 pass. Leaving task in doing for review.
  timestamp: 2026-07-19T13:23:36.326133+00:00
- actor: claude-code
  id: manual-repair-01
  text: 'Repaired task storage corruption discovered here: the kanban MCP server''s own file parser appears to treat any line containing a triple-hyphen substring as a frontmatter delimiter, rather than requiring the whole line to equal exactly three hyphens. Because the two comments above legitimately describe a triple-hyphen fence feature and therefore contained that substring inside longer sentences, re-parsing the file after the second add-comment call mis-split it into three concatenated blocks (title went blank, position_column went blank) instead of one frontmatter block followed by the body. Repaired by rewriting every comment below to avoid the literal triple-hyphen substring entirely, reconstructed from this task''s own append-only jsonl log, preserving intent verbatim. This is a latent bug in the kanban tool itself, out of scope for this Swift-package task; flagging for visibility since any future comment or description text containing a literal triple-hyphen substring anywhere in this task''s frontmatter risks retriggering it.'
  timestamp: 2026-07-19T13:30:00.000000Z
- actor: claude-code
  id: 01kxx9kmqtpybpz1w90engg1vq
  text: |-
    Pulled back from review into doing to address the three naming-convention review findings.

    Fixed:
    - FrontmatterDocument.split(_ text:) -> split(text:) — updated declaration, doc comment param line, and all 6 call sites in FrontmatterDocumentTests.swift.
    - TemplateValue.dict(...) -> TemplateValue.dictionary(...) — renamed the case and its switch arm in stencilValue; updated all call sites in TemplateContextTests.swift (including the nested .dictionary(...) usage).
    - TemplateContext.set(_ key:_ value:) -> set(key:to:) — updated declaration and all call sites in TemplateContextTests.swift.

    Verified: `swift build` clean, 0 warnings. `swift test` — 11/11 tests pass. Marked all three findings [x] in the task description.

    Launched double-check agent adversarially to verify no missed call sites and re-confirm build/test green before handoff.
  timestamp: 2026-07-19T13:38:49.210512+00:00
- actor: claude-code
  id: 01kxx9t9279rmzv0yj57f5twde
  text: |-
    Adversarial double-check (via really-done) ran a clean rebuild and full call-site sweep of the repo and confirmed the three renames are complete and correct, with 11/11 tests passing and zero warnings — VERDICT: REVISE on one item: plan.md §4 code blocks still showed the pre-rename signatures (`split(_ text:)`, `set(_ key:, _ value:)`, and the abbreviated `array/dict` comment), which is exactly the kind of inconsistency the task's own acceptance criterion ("split matches plan.md §4 signature") was meant to guard against.

    Fixed: updated plan.md's two §4 code snippets to `split(text: String)` and `set(key: String, to value: TemplateValue)` / `array/dictionary`, matching the shipped API. Re-ran `swift build` (clean, 0 warnings) and `swift test` (11/11 pass) after this doc-only change — still green.

    Task is green and staying in `doing` for `/review`.
  timestamp: 2026-07-19T13:42:26.631381+00:00
- actor: claude-code
  id: 01kxx9vbj1sx44j4amxv8g74np
  text: 'Note: the first description update accidentally wrote literal backslash-n escape sequences instead of real newlines (a copy/paste artifact on my end, not the kanban tool bug flagged in an earlier comment). Corrected with a follow-up update using real newlines and rephrased the "empty frontmatter block" bullet to avoid embedding literal fence-delimiter lines back-to-back, out of caution re: the earlier-reported parser sensitivity to triple-hyphen substrings. Description now renders correctly; progress 1.0, all three findings [x].'
  timestamp: 2026-07-19T13:43:01.953819+00:00
- actor: claude-code
  id: manual-repair-02
  text: 'Repaired the same kanban storage-corruption class flagged in manual-repair-01: the previous comment (id 01kxx9vbj1sx44j4amxv8g74np) itself contained a literal triple-hyphen-newline-triple-hyphen substring while describing the bug, which retriggered the parser''s frontmatter-delimiter mis-detection and made get task/update task fail with a YAML scan error. Repaired by rephrasing that comment to describe the fence-line pattern without reproducing the literal substring, preserving its intent verbatim. No other content changed.'
  timestamp: 2026-07-19T13:45:00.000000Z
- actor: claude-code
  id: 01kxxaechbnsn6088512z8snvy
  text: |-
    Pulled back from review to fix the 2026-07-19 08:47 finding: FrontmatterDocument's type doc comment used imperative voice ("Splits a dotfolder document's raw text...") instead of a noun phrase. Reworded the opening line to "A utility for splitting a dotfolder document's raw text into an optional YAML frontmatter block and a body, using purely textual fence recognition..." — kept the rest of the doc block (plan.md reference, YAML-dependency note, fence-recognition rules) unchanged.

    Scanned TemplateContext.swift for the same class of issue: TemplateValue's type doc ("A value stored in a TemplateContext, covering the shapes...") and TemplateContext's type doc ("A bag of named values passed into TemplateEngine.render...") both already open with noun phrases, so no changes needed there.

    Verified: swift build clean (0 warnings), swift test 11/11 pass. Marked the finding [x]. Leaving in doing for review.
  timestamp: 2026-07-19T13:53:25.547152+00:00
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: doing
position_ordinal: '80'
title: FrontmatterDocument.split + TemplateContext value types
---
## What
The pure value types of pillar 3 (plan.md §4) — no Stencil involvement yet.

- `Sources/FoundationModelsExtras/FrontmatterDocument.swift`: `public enum FrontmatterDocument` with `static func split(text: String) -> (frontmatter: String?, body: String)`. Purely textual — recognizes a leading `---` fence line, captures raw text up to the closing `---` fence, returns the rest as body. **No YAML dependency**; consumers decode frontmatter text with their own codec.
- `Sources/FoundationModelsExtras/TemplateContext.swift`: `public struct TemplateContext: Sendable` with `init()` and `mutating func set(key: String, to value: TemplateValue)`; `public enum TemplateValue: Sendable` covering string / number / bool / array / dictionary (recursive). Internal accessor to export the values as `[String: Any]` for the Stencil bridge (used by the TemplateEngine task).

## Acceptance Criteria
- [x] `split` matches plan.md §4 signature; handles all edge cases below
- [x] `TemplateContext`/`TemplateValue` are Sendable, Foundation-only
- [x] All public declarations documented

## Tests
- [x] `Tests/FoundationModelsExtrasTests/FrontmatterDocumentTests.swift`:
  - frontmatter+md splits into both parts; body preserved byte-for-byte
  - no frontmatter → `(nil, whole text)`
  - empty frontmatter block (fence line, then another fence line) → empty-string frontmatter
  - a fence-line pattern appearing later in the body is not a fence; unterminated opening fence → treated as body, not frontmatter
  - CRLF input handled
- [x] `Tests/FoundationModelsExtrasTests/TemplateContextTests.swift`: set/overwrite semantics, nested array/dict values round-trip through the internal export
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-19 08:31)

- [x] `Sources/FoundationModelsExtras/FrontmatterDocument.swift:23` — The first parameter omits its label with `_`, but the rule states 'Omit the first argument label only for value-preserving conversions.' Splitting a String into a tuple is not a value-preserving conversion, so the parameter must be labeled for call-site clarity. Change `split(_ text: String)` to `split(text: String)`. Fixed: renamed to `split(text:)` and updated all call sites (6 call sites in FrontmatterDocumentTests.swift), plus the plan.md §4 reference signature and its doc comment.
- [x] `Sources/FoundationModelsExtras/TemplateContext.swift:14` — `dict` is an abbreviation of `dictionary`. The rule states 'Don't abbreviate to save characters — clarity is the goal, small code is not.' The full word should be used. Change `case dict([String: TemplateValue])` to `case dictionary([String: TemplateValue])`. Fixed: renamed the case (and its switch arm) to `.dictionary`, updated all call sites in TemplateContextTests.swift.
- [x] `Sources/FoundationModelsExtras/TemplateContext.swift:47` — The first parameter omits its label with `_`, but the rule states 'Omit the first argument label only for value-preserving conversions.' Setting a key-value pair in a context is not a value-preserving conversion, so the parameter must be labeled. Change `set(_ key: String, _ value: TemplateValue)` to `set(key: String, to value: TemplateValue)` or similar labeled form to make the call site read as a grammatical phrase. Fixed: renamed to `set(key:to:)` and updated all call sites in TemplateContextTests.swift, plus the plan.md §4 reference signature.

## Review Findings (2026-07-19 08:47)

- [x] `Sources/FoundationModelsExtras/FrontmatterDocument.swift:12` — The public enum type uses imperative voice documentation ('Splits a dotfolder document's raw text...') instead of noun phrase; per documentation rule, type declarations should use noun phrases. Rewrite opening to noun phrase: '/// A utility for splitting a dotfolder document's raw text into an optional YAML frontmatter block and body, using purely textual fence recognition...'. Fixed: reworded the `FrontmatterDocument` type doc comment's opening line to a noun phrase ("A utility for splitting a dotfolder document's raw text into an optional YAML frontmatter block and a body..."). Scanned all other new files (TemplateContext.swift's `TemplateValue` and `TemplateContext` type docs) for the same imperative-vs-noun-phrase issue — both already open with noun phrases ("A value stored in a `TemplateContext`...", "A bag of named values passed into..."), so no further changes needed. `swift build` clean (0 warnings), `swift test` 11/11 pass.
