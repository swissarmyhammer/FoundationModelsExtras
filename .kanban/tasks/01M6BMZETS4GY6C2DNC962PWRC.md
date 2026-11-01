---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6byb09bfbks9begahccjnre
  text: |-
    ### implement — changed
    - Cause found: the stand-in tokenizer_config.json names no eos_token, so tokenizer.eosToken was nil. A text longer than 128 tokens was cut without its end token (id 1). The 6 other reference texts matched at once.
    - Fix: CoreMLTokenRow takes the pad token and the end token from the tokenizer (new init with tokenizer). The end token falls back to the vocabulary token "<eos>". CoreMLEmbedding uses this path.
    - Tests: unit test longRowKeepsTheVocabularyEndToken (red, then green). Integration test tokenIdsEqualPythonTokenizers with 7 reference texts (short, prefixes, 400 words, Japanese, French and German, spaces and newline) in Support/ReferenceTokenCases.swift; ids from Python tokenizers (venv in scratchpad, python -I).
    - Results: swift test: 131 and 40 and 44 tests pass. Integration CoreMLPooledEmbedderIntegrationTests: 10 tests pass.
    - next: /review
  timestamp: 2026-11-01T16:16:02.859559+00:00
- actor: claude-code
  id: 01m6byg8bswb5c50asm4yrsphe
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD, 18 findings, all in IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift (lines 32, 37, 38, 43, 44, 47, 49-56, 61, 66, 67, 72), rule code-hygiene/magic-numbers-swift
    - next: the implementer replaces the magic numbers with named constants in the whole file, then the task is reviewed again
  timestamp: 2026-11-01T16:18:54.969668+00:00
- actor: claude-code
  id: 01m6bygeyka19cmg4jmde2xptb
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files
    - test: green — swift test, 1632 passed
    - commit: 5864b5f
    - review: findings — ReferenceTokenCases.swift:32,37,38,43,44,47,49-56,61,66,67,72 (magic-numbers-swift)
  timestamp: 2026-11-01T16:19:01.715980+00:00
- actor: claude-code
  id: 01m6bykcv11azkr717b173hjtk
  text: |-
    ### implement — changed
    - Cause: the file held the reference token ids as number literals in Swift arrays, and the word count 400 in the long text.
    - Fix: the ids moved to the JSON resource Support/ReferenceTokenIds.json (a map from case name to ids). ReferenceTokenCases.swift keeps the texts and a function loadReferenceTokenCases() that reads the resource. The word count is the named constant longTextWordCount. Package.swift of IntegrationTests lists the resource. The test calls the function.
    - Result: integration CoreMLPooledEmbedderIntegrationTests: 10 tests pass, including tokenIdsEqualPythonTokenizers. No new build warning.
    - Not committed.
    - next: /review
  timestamp: 2026-11-01T16:20:37.857168+00:00
- actor: claude-code
  id: 01m6bynmmsa0dz1j2myfd3arp9
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD; findings 0, confirmed 0, refuted 1; all prior items checked
    - next: none; task moved to done
  timestamp: 2026-11-01T16:21:51.385262+00:00
- actor: claude-code
  id: 01m6bynsy0k9rpc62ag4fzxtz2
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 files
    - test: skipped — only the integration package changed; Core ML integration suite passed 10 tests
    - commit: 0136cbb
    - review: clean — 0 findings
  timestamp: 2026-11-01T16:21:56.800889+00:00
position_column: done
position_ordinal: ffcc80
title: Check that the Core ML tokenizer gives the same token ids as the Python tokenizers library
---
CoreMLEmbedding tokenizes with swift-transformers and a stand-in tokenizer_config.json (the PreTrainedTokenizer class), because erjigit17/embeddinggemma-300m-ane-coreml has no tokenizer_config.json. A text that is longer than the model length keeps its first tokens and its end token. Compare the ids for 5 or more sample texts (short, long, non-English, with the query and document prefixes) with the ids that the Python tokenizers library gives for the same tokenizer.json with padding to 128 and truncation to 128. Add a fixture-based unit test or an integration test with the expected ids. Fix any difference in the start token, the end token or the truncation.

## Review Findings (2026-11-01 10:17)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:32` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:37` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:38` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:43` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:44` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:47` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:49` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:50` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:51` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:52` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:53` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:54` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:55` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:56` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:61` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:66` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:67` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/ReferenceTokenCases.swift:72` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
