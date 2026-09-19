---
depends_on:
- 01M2XDHRDADTN57M8EVQTWJZX9
position_column: todo
position_ordinal: '8580'
title: Document the Marketplace pillar in README, plan.md and CHANGELOG
---
## What

Record the new `Marketplace` product in the three documents that describe the package, in the shape the earlier capabilities used (`IgnoreProcessor`, `Doctorable`, `ProcessRunner`).

1. `README.md`: add a section `## Remote layers: \`MarketplaceStore\`` before `## Install`, with a short runnable example: make a `MarketplaceStore` from one `MarketplaceSource`, give it a `MarketplaceLayout`, call `marketplaceLayers()`, insert each layer at the bottom of a `DotfolderStack`, and read one file through the stack. Add the marketplace to the capability list in the lead paragraph. State in one line that a marketplace layer always renders untrusted and that there is no per-marketplace permission.
2. `plan.md`: append `## 12. Pillar 6 — Marketplace (a fetched, cached, materialized layer root)`. State the decision of 2026-09-19 (the user: Extras owns all marketplace file reading; a consumer reads a materialized root like a local layer), the split (transport, catalog, cache, writer, store, config here; the registry, the diagnostics provenance and the CLI in the consumer), the `MarketplaceLayout` inputs, and the "no grant" rule. In §5, extend the dependency budget: `swift-libgit2` (`exact: "1.9.7"`) and Yams on the separate `Marketplace` target only, never on the core target, with the reason. In §6, add `FoundationModelsSkills` as the consumer of `Marketplace`.
3. `CHANGELOG.md`: add `### Added: the \`Marketplace\` product` at the top of `## Unreleased`, in the shape of the `ProcessRunner` entry: the opening paragraph with the API, **Cause.** (the capability leaves `FoundationModelsSkills`, and why), **What changed.** with each public type. State that `MarketplaceSource` has no `grants` field.
4. The README example is contract-tested, the same as the `ProcessRunner` example: put the example text in a test and compile it.

## Acceptance Criteria

- [ ] `README.md` has the new section, and its example compiles and runs in a test.
- [ ] `plan.md` §12 names the decision date, the split, `MarketplaceLayout`, and the "no grant" rule; §5 names the libgit2 and Yams budget for the `Marketplace` target; §6 names the consumer.
- [ ] `CHANGELOG.md` has the entry at the top of `## Unreleased`.
- [ ] No document in this package names a marketplace grant.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.
- [ ] The work is committed and pushed to `main` of this repository.

## Tests

- [ ] `Tests/MarketplaceTests/ReadmeSnippetTests.swift`: the README example text and the test copy are the same text, and the example builds a store over a `GitFixtureRepository` and reads one file through the stack.
- [ ] `Tests/MarketplaceTests/DocumentationTests.swift`: `README.md` holds the section heading, `plan.md` holds the `## 12.` heading and the string `2026-09-19`, `CHANGELOG.md` holds the entry heading, and none of the three holds the string `MarketplaceGrants`.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#marketplace #docs