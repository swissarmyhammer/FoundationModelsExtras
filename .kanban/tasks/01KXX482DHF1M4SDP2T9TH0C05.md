---
comments:
- actor: claude-code
  id: 01kxxtqsb4z2sw3h9wfqfe9g5t
  text: |-
    Implemented CorpusGoldenTests.swift plus the fixture tree.

    Corpus audit: grep for `{{`/`{%` across ../swissarmyhammer/builtin/ found 49 templated files; plus 7 plain partials those files transitively reference via include/render (architecture-awareness, task-standards, short-ids, record-progress, review-column, task-double-check, validators) = 56 total files copied preserving relative layout into Tests/FoundationModelsExtrasTests/Fixtures/Corpus/.

    Migration applied directly to the copied fixtures:
    - _partials/coding-standards.md: the one {% render %} became {% include %}
    - _partials/skills.md: available_skills.size became available_skills.count

    Verified via Stencil source (Variable.swift, Expression.swift, IfTag.swift, ForTag.swift) that an absent context key resolves to nil without throwing, and nil safely evaluates falsy in both {% if %} numeric/variable expressions and {% for %} (empty result) -- so the "absent" branch variant is implemented by simply omitting the available_skills/arguments keys, no special-casing needed.

    Golden mirrors: Fixtures/Expected/ (populated context: fixed available_skills array + arguments + version) and Fixtures/ExpectedAbsent/ (absent: available_skills/arguments omitted, version still set) -- both full mirrors of the 56-file corpus, generated via a CORPUS_GOLDEN_UPDATE=1 env-var regeneration path in the test itself (reviewed by hand after generation, matching the "generated once and reviewed by hand" instruction).

    no-secrets.md special case: decided to pin the eaten-placeholder output (not exclude the file) -- Stencil renders the literal `{{secret}}` prose example as empty, producing an empty backtick pair in the rendered "Configuration file placeholders" line. Documented with an inline comment and a dedicated test.

    TDD: ran swift test --filter CorpusGoldenTests before generating any Expected/ExpectedAbsent content -- confirmed RED (112 issues: 56 files x 2 context variants, all "no checked-in expected output"). Generated once with CORPUS_GOLDEN_UPDATE=1, hand-reviewed the output (spot-checked coding-standards.md's nested-frontmatter carryover from the migrated include, skills.md's if/for both branches, ci/SKILL.md and map/SKILL.md's if-arguments both branches, no-secrets.md's eaten placeholder), then re-ran normally -- GREEN.

    Side finding: adding Fixtures/ under the test target's own source path made SwiftPM emit a new "unhandled files" build warning (168 files). Fixed by declaring resources: [.copy("Fixtures")] on the FoundationModelsExtrasTests target in Package.swift -- confirmed via git stash that this warning did not exist before this change and is gone after the fix.

    Full suite: swift test -> 103 tests, 12 suites, all passed, exit 0, zero warnings.

    Adversarial double-check spawned to verify acceptance criteria against the actual fixtures/test code before handoff.
  timestamp: 2026-07-19T18:38:10.788896+00:00
- actor: claude-code
  id: 01kxxtyt9cdxa7qqxtc5489x9h
  text: |-
    Adversarial double-check verdict: PASS.

    Independently re-derived (not taken on the implementer's word): grepped the entire ../swissarmyhammer/builtin tree for {{/{% and confirmed exactly 49 templated files, all present in Fixtures/Corpus/; traced every include/render reference across the whole builtin tree and confirmed exactly 9 distinct referenced partials, all present under Corpus/_partials/ (49+7=56 matches exactly); confirmed _partials/validator-tools.md and _partials/project-types/*.md are correctly excluded (unreferenced); confirmed the migration diffs in coding-standards.md and skills.md match upstream exactly aside from the two intended edits; confirmed exactly 3 files in the corpus branch on {% if %}/{% for %} (skills.md, ci/SKILL.md, map/SKILL.md) with no missed site; confirmed Corpus/Expected/ExpectedAbsent all have identical 56-file relative layouts; hand-traced planner/AGENT.md's nested double-include through both context mirrors; confirmed no-secrets.md's eaten-placeholder pin is byte-identical to upstream plus the expected empty-backtick substitution; confirmed corpusFiles() uses FileManager.subpathsOfDirectory with no hand-kept list anywhere; confirmed the byte comparison has no trimming/normalization; confirmed CORPUS_GOLDEN_UPDATE only fires when explicitly set (off by default, can't vacuously pass in CI); confirmed Trust.untrusted is a real enforcement path (tag/filter whitelist, include-depth limit, output-size limit) so the untrusted==trusted assertion is meaningful; independently re-ran swift test --filter CorpusGoldenTests (5/5 pass) and full swift test (103 tests, 12 suites, all pass).

    Verification command run fresh by the implementing agent immediately before handoff: swift test -> 103 tests, 12 suites, all passed, exit 0, zero warnings.

    Leaving task in doing per /implement process (review column transition belongs to /review).
  timestamp: 2026-07-19T18:42:01.132295+00:00
depends_on:
- 01KXX47408MG0KP7BAQWFKZFDW
- 01KXX47J8F72GSX5STK6YVDQZP
position_column: doing
position_ordinal: '80'
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
- [x] Every templated corpus file (including `validators/`) renders without error and matches its checked-in expected output
- [x] The two migrated constructs (`render`→`include`, `.size`→`.count`) render to the intended output
- [x] `{% if %}` sites are pinned in both truthy and falsy context variants
- [x] Corpus renders clean under `Trust.untrusted` as well
- [x] Fixture tree checked in; test discovers files by enumeration, not a hand-kept list

## Tests
- [x] `Tests/FoundationModelsExtrasTests/CorpusGoldenTests.swift` implementing the above; failure output names the file and shows a diff
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Resolution notes
Decided to pin the no-secrets.md eaten-placeholder output (not exclude the file), documented inline in the test and via a dedicated test case. Full corpus audit found 49 templated files plus 7 transitively-referenced plain partials (56 total). Absent-branch context variant implemented by omitting the available_skills/arguments keys entirely (verified against Stencil's own resolution/expression source that this evaluates falsy without error). Added resources: [.copy("Fixtures")] to the test target in Package.swift to silence a new SwiftPM unhandled-files warning introduced by the fixture tree. Adversarial double-check returned PASS with independent re-derivation of file counts, migration diffs, branch-site coverage, and mirror-tree parity.