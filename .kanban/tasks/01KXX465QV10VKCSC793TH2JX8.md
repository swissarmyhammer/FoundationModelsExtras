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
  text: |-
    Repaired task storage corruption discovered here: the kanban MCP server's own file parser appears to treat any line containing a triple-hyphen substring as a frontmatter delimiter, rather than requiring the whole line to equal exactly three hyphens. Because the two comments above legitimately describe a triple-hyphen fence feature and therefore contained that substring inside longer sentences, re-parsing the file after the second add-comment call mis-split it into three concatenated blocks (title went blank, position_column went blank) instead of one frontmatter block followed by the body. Repaired by rewriting every comment below to avoid the literal triple-hyphen substring entirely, reconstructed from this task's own append-only jsonl log, preserving intent verbatim. This is a latent bug in the kanban tool itself, out of scope for this Swift-package task; flagging for visibility since any future comment or description text containing a literal triple-hyphen substring anywhere in this task's frontmatter risks retriggering it.
  timestamp: 2026-07-19T13:30:00.000000Z
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: doing
position_ordinal: '80'
title: FrontmatterDocument.split + TemplateContext value types
---
## What
The pure value types of pillar 3 (plan.md §4) — no Stencil involvement yet.

- `Sources/FoundationModelsExtras/FrontmatterDocument.swift`: `public enum FrontmatterDocument` with `static func split(_ text: String) -> (frontmatter: String?, body: String)`. Purely textual — recognizes a leading `---` fence line, captures raw text up to the closing `---` fence, returns the rest as body. **No YAML dependency**; consumers decode frontmatter text with their own codec.
- `Sources/FoundationModelsExtras/TemplateContext.swift`: `public struct TemplateContext: Sendable` with `init()` and `mutating func set(_ key: String, _ value: TemplateValue)`; `public enum TemplateValue: Sendable` covering string / number / bool / array / dict (recursive). Internal accessor to export the values as `[String: Any]` for the Stencil bridge (used by the TemplateEngine task).

## Acceptance Criteria
- [x] `split` matches plan.md §4 signature; handles all edge cases below
- [x] `TemplateContext`/`TemplateValue` are Sendable, Foundation-only
- [x] All public declarations documented

## Tests
- [x] `Tests/FoundationModelsExtrasTests/FrontmatterDocumentTests.swift`:
  - frontmatter+md splits into both parts; body preserved byte-for-byte
  - no frontmatter → `(nil, whole text)`
  - empty frontmatter block (`---\n---\n`) → empty-string frontmatter
  - `---` appearing later in the body is not a fence; unterminated opening fence → treated as body, not frontmatter
  - CRLF input handled
- [x] `Tests/FoundationModelsExtrasTests/TemplateContextTests.swift`: set/overwrite semantics, nested array/dict values round-trip through the internal export
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
