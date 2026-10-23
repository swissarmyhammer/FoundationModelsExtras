---
comments:
- actor: claude-code
  id: 01m5k4e4q0xdwzxzhngmadnvwd
  text: 'Research: the frontmatter writer is FrontmatterDocument+Save.swift `yaml(of:)`, which calls Yams `YAMLEncoder().encode`. Yams 6.2.2 (latest pin) boxes Double/Float through `formattedStringForCodable`: `%.17g`, and when that has no exponent it falls back to a NumberFormatter in `.scientific` style with only 15 (Double) / 7 (Float) significant digits. So 6 -> `6e+0`, 0.25 -> `2.5e-1`, and the fallback is also lossy: 0.1 + 0.2 (0.30000000000000004) renders as 3e-1 and decodes back as 0.3. No Yams option or hook changes this (`_Encoder` is private; `Double.box()` is a fixed retroactive conformance). A text post-pass over Yams'' output cannot recover the lost digits. Plan: an internal Encoder in the core target that builds the Yams `Node` itself, boxes every other `YAMLEncodable` with Yams'' own `box()` (Date, Data, URL, etc. unchanged), boxes Double/Float with their shortest round-trip `description` expanded to plain decimal (no exponent, `.0` kept on whole numbers so the scalar stays float-tagged), and serializes with `Yams.serialize(node:)` (same defaults as `YAMLEncoder()`). MarketplaceConfig.save also uses YAMLEncoder but is outside this card.'
  timestamp: 2026-10-23T01:01:36.352038+00:00
- actor: claude-code
  id: 01m5k4sgn5q9rn1hnf95t6ct3f
  text: |-
    Implementation landed (TDD). RED: four new tests in FrontmatterDocumentSaveTests failed on Yams output `6e+0`, `2.5e-1`, `1.00000001490116e-1` (Float 0.1), and the lossy `3e-1` for 0.1 + 0.2. That also confirmed Yams' 15-digit fallback loses precision.

    GREEN: new internal `PlainNumberYAMLEncoder` (Sources/FoundationModelsExtras/PlainNumberYAMLEncoder.swift). It is an Encoder that builds the Yams Node tree itself. Any `BinaryFloatingPoint & LosslessStringConvertible` value (Double, Float) becomes a float-tagged scalar holding its shortest round-trip `description`, with the exponent written out as digits. Whole numbers keep `.0`, so the scalar still resolves as a float. Non-finite values become `.inf`, `-.inf` and `.nan`. Every other YAMLEncodable value (Date, String, Int, Data, URL...) uses Yams' own `box()`, so its output does not change. The tree is written with `Yams.serialize(node:)` using the same default options as `YAMLEncoder()`. `FrontmatterDocument.yaml(of:)` now calls it, and FrontmatterDocument+Save.swift no longer imports Yams.

    Output now: `grace: 6.0`, `step: 0.25`, 1e20 -> `100000000000000000000.0`, 1e-5 -> `0.00001`, Float 0.1 -> `0.1`. Round trip is exact for 0.1+0.2, -2.5, greatestFiniteMagnitude, leastNonzeroMagnitude and ±infinity.

    Sibling check: Marketplace/MarketplaceConfig.save also uses Yams `YAMLEncoder`, but Sources/Marketplace has no Double/Float/TimeInterval field, so it is not affected. It is left unchanged because it is outside this card.
  timestamp: 2026-10-23T01:07:49.029282+00:00
- actor: claude-code
  id: 01m5k4sjy0hexh9zazr3hkzq8q
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/PlainNumberYAMLEncoder.swift (new), Sources/FoundationModelsExtras/FrontmatterDocument+Save.swift, Tests/FoundationModelsExtrasTests/FrontmatterDocumentSaveTests.swift. `swift test`: 1561 tests in 160 suites passed, 0 failures; the only warning is the allowed mlx bundle warning. `swift format lint --strict` is clean on the changed files.
    - next: /review (task left in doing)
  timestamp: 2026-10-23T01:07:51.360180+00:00
- actor: claude-code
  id: 01m5k51aacq1a1at6zvnegdcfm
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (6850fd4) — 0 findings (attempted 7, failed 0, skipped 0); 3 files reviewed, 2 .kanban/ files excluded by .reviewignore
    - next: none — moved to done
  timestamp: 2026-10-23T01:12:04.684737+00:00
- actor: claude-code
  id: 01m5k51nyksvqj1g7recag8dhm
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files
    - test: green — swift test, 1561 passed in 160 suites
    - commit: 6850fd4
    - review: clean — 0 findings
  timestamp: 2026-10-23T01:12:16.595184+00:00
position_column: done
position_ordinal: ffc380
title: FrontmatterDocument save writes a whole-number Double as 6e+0
---
Reported by agentviewkit-05 while adopting Router index.md (AgentViewKit ^b36r42y). Router's SessionConfiguration.inlineSettleGrace (a TimeInterval, value 6) is saved in the index.md frontmatter through FrontmatterDocument.save(to:) / rendered() as `6e+0`. It decodes back correctly, but index.md is meant to be read by people, so a Double should render as plain decimal text (`6`, or `6.0`, and `0.25` rather than `2.5e-1`).

- [x] Failing test: rendering Encodable metadata holding a Double 6 and 0.25 gives `6`/`6.0` and `0.25`, with no exponent
- [x] The rendered value still decodes back to the same Double
- [x] Fix the Double/Float encoding in the frontmatter writer