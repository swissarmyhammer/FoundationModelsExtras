---
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: todo
position_ordinal: '8380'
title: FrontmatterDocument.split + TemplateContext value types
---
## What
The pure value types of pillar 3 (plan.md §4) — no Stencil involvement yet.

- `Sources/FoundationModelsExtras/FrontmatterDocument.swift`: `public enum FrontmatterDocument` with `static func split(_ text: String) -> (frontmatter: String?, body: String)`. Purely textual — recognizes a leading `---` fence line, captures raw text up to the closing `---` fence, returns the rest as body. **No YAML dependency**; consumers decode frontmatter text with their own codec.
- `Sources/FoundationModelsExtras/TemplateContext.swift`: `public struct TemplateContext: Sendable` with `init()` and `mutating func set(_ key: String, _ value: TemplateValue)`; `public enum TemplateValue: Sendable` covering string / number / bool / array / dict (recursive). Internal accessor to export the values as `[String: Any]` for the Stencil bridge (used by the TemplateEngine task).

## Acceptance Criteria
- [ ] `split` matches plan.md §4 signature; handles all edge cases below
- [ ] `TemplateContext`/`TemplateValue` are Sendable, Foundation-only
- [ ] All public declarations documented

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/FrontmatterDocumentTests.swift`:
  - frontmatter+md splits into both parts; body preserved byte-for-byte
  - no frontmatter → `(nil, whole text)`
  - empty frontmatter block (`---\n---\n`) → empty-string frontmatter
  - `---` appearing later in the body is not a fence; unterminated opening fence → treated as body, not frontmatter
  - CRLF input handled
- [ ] `Tests/FoundationModelsExtrasTests/TemplateContextTests.swift`: set/overwrite semantics, nested array/dict values round-trip through the internal export
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.