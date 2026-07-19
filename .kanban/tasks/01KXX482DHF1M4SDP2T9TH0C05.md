---
depends_on:
- 01KXX47408MG0KP7BAQWFKZFDW
- 01KXX47J8F72GSX5STK6YVDQZP
position_column: todo
position_ordinal: '8780'
title: Corpus migration golden tests (render → include)
---
## What
Pin the swissarmyhammer content carryover with golden tests (plan.md §4): the Liquid corpus renders through Stencil nearly verbatim, with a small, explicit one-time migration.

- Copy the *templated* subset of `../swissarmyhammer/builtin/` (files containing `{{ }}` or `{% %}` constructs, plus every partial they reference) into `Tests/FoundationModelsExtrasTests/Fixtures/Corpus/` preserving relative layout — that includes `_partials/`, `agents/`, `skills/`, **and `validators/`** (~20 validator files use `{{version}}` in frontmatter).
- One-time migration (plan.md's "nothing else changes" needs two qualifications found by corpus audit):
  - `{% render '_partials/validators' %}` in `_partials/coding-standards.md` → `{% include "_partials/validators" %}`
  - `available_skills.size` in `_partials/skills.md` → `available_skills.count` — `.size` is Liquid; Stencil resolves `.count` on collections, and `.size` would silently evaluate falsy
- Special case: `validators/no-secrets/rules/no-secrets.md` contains a **literal** `` {{secret}} `` (documentation of a placeholder pattern, not a template variable). Stencil renders missing variables as empty string, silently corrupting that line. Either exclude the file from the golden suite or deliberately pin the eaten-placeholder output with a comment explaining why — decide and document in the test.
- Golden context must exercise every branch: define `available_skills` (small fixed array), `version`, and `arguments` — and render `{% if %}` sites in both truthy and absent variants so both branches are pinned.
- Check in expected rendered outputs beside the fixtures (`Expected/` mirror tree), generated once and reviewed by hand.
- Golden test renders every corpus file through `TemplateEngine` (trusted, partials stack rooted at the corpus fixture) and diffs against the expected output byte-for-byte. A second pass renders the same corpus **untrusted** and asserts it passes validation — the corpus uses only whitelisted constructs.

## Acceptance Criteria
- [ ] Every templated corpus file (including `validators/`) renders without error and matches its checked-in expected output
- [ ] The two migrated constructs (`render`→`include`, `.size`→`.count`) render to the intended output
- [ ] `{% if %}` sites are pinned in both truthy and falsy context variants
- [ ] Corpus renders clean under `Trust.untrusted` as well
- [ ] Fixture tree checked in; test discovers files by enumeration, not a hand-kept list

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/CorpusGoldenTests.swift` implementing the above; failure output names the file and shows a diff
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.