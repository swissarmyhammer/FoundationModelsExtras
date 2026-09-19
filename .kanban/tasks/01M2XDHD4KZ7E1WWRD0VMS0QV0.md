---
depends_on:
- 01M2XDH57XW45Z6W0V3JHJ8KD2
position_column: todo
position_ordinal: '8180'
title: Move the marketplace source model, the policy and the config loader
---
## What

In the `Marketplace` target that the transport card added, move the pure value types of a marketplace source, the policy, and the `marketplaces.yaml` loader. These files do no git work and no snapshot work.

The grant removal card on the `FoundationModelsSkills` board (`^8mxhn6a` on that board) lands first, so `MarketplaceSource` arrives with no `grants` field and there is no `MarketplaceGrants` type. If that card is not done yet when this card starts, remove the grants here and do not carry them over.

1. Move these files from `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/` into `Sources/Marketplace/`, with 2-space indentation and the same type names: `MarketplaceSource.swift` (`MarketplaceSource` only), `SkillSelection.swift`, `SourcePattern.swift`, `MarketplaceLocation.swift`, `MarketplaceIdentity.swift` (it imports `CryptoKit`), `MarketplaceSourceError.swift`, `MarketplacePinError.swift`, `MarketplacePolicy.swift`, `MarketplaceConfig.swift`, `MarketplaceConfigError.swift`.
2. `MarketplaceConfig` keeps `load(from:includeProject:)` over a `DotfolderStack` and `save(to:)`. It reads the `.user` and `.project` layers only. It keeps Yams for the decode and the encode; the target declares that dependency.
3. `MarketplaceIdentity` keeps the env variable names `SKILLS_MARKETPLACE_CACHE` and `SKILLS_MARKETPLACE_SEED`, and the default cache path under `~/.cache/skills/marketplaces`. These are documented host contracts; a rename is not part of the move.
4. Move the tests: `MarketplaceSourceTests.swift` (without the grants cases), `SourcePatternTests.swift`, `MarketplaceConfigTests.swift` into `Tests/MarketplaceTests/`. `MarketplaceConfigTests` builds its stack from a temporary directory; take the temporary directory helper from `FixtureSupport`. Move `makeTempDirectory(withFiles:)` and `writeFile(text:to:)` of the Skills `MarketplaceTestSupport` into `Tests/MarketplaceTests/MarketplaceTestSupport.swift` if the tests need them.
5. Scrub the doc comments of the moved files: no comment names `RenderPolicy`, `allowed-tools` or `SkillsRegistry`. The doc of `MarketplaceSource` in Skills names the first two; a later card adds a boundary test over the whole target that fails on those names.
6. Do not delete anything in `FoundationModelsSkills`.

## Acceptance Criteria

- [ ] Every §5.1 source form of the Skills `marketplace.md` parses to the same `MarketplaceLocation` here as in Skills: HTTPS `.git`, `github:owner/repo`, `#ref` suffix, `file://`, and the scp-like SSH form (accepted by the parser, refused by the transport).
- [ ] `MarketplacePolicy` refuses a source by the allowlist and the blocklist before any I/O, and reads `SKILLS_MARKETPLACE_AUTOUPDATE` from its environment.
- [ ] `MarketplaceConfig.load(from:includeProject:)` merges the user list and the project list with the alias-or-URL merge key, and `save(to:)` writes a file that loads back equal.
- [ ] No type in `Sources/Marketplace` names a grant, and no doc comment of the moved files names `RenderPolicy`, `allowed-tools` or `SkillsRegistry`.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/MarketplaceTests/MarketplaceSourceTests.swift`: the URL forms, the identity rules (pre-fetch key from alias or repository name), `SkillSelection` decode of `all`, `plugins:` and `skills:`, and each `MarketplaceSourceError` case.
- [ ] `Tests/MarketplaceTests/SourcePatternTests.swift`: the match table of `.owner`, `.repository` and `.prefix` over the normalized URL.
- [ ] `Tests/MarketplaceTests/MarketplaceConfigTests.swift`: a project entry with the same key replaces the user entry in the project position; `includeProject: false` reads the user file only; a `grants:` key in an entry is ignored; save then load gives an equal value.
- [ ] `Tests/MarketplaceTests/MarketplacePolicyValueTests.swift`: the allowlist and the blocklist decide with no store and no I/O.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#marketplace #cross-repo