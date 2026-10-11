---
comments:
- actor: claude-code
  id: 01m4nqx2dya9thgpgpfrjcnvcn
  text: |-
    Research:
    - `MLXEmbedding.embed(texts:)` is a private struct in `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`. It tokenizes in `container.perform`, pads with the internal `EmbeddingBatchPadding`, runs the model with a row-length mask, and pools.
    - The MLXEmbedders Qwen3 model folds the key-padding mask into a causal mask of shape [rows, 1, L, L]. Thus the attention memory of one tensor is about rows x L x L. The budget limits rows x L, so it also limits this memory to budget x L.
    - Plan: add an internal pure type `EmbeddingSubBatches` (next to `EmbeddingBatchPadding`). It sorts the rows by token count, divides them by a token budget, and puts the vectors of the sub-batches back in input order. Unit tests in `Tests/FoundationModelsExtrasTests/ModelPool/`. A real-model test goes in `IntegrationTests/.../PooledEmbedderIntegrationTests.swift`. The reference for "one padded call" is one call with N copies of the long text: it has the same tensor shape (N x longest) as the old padded call.
  timestamp: 2026-10-11T15:04:35.518703+00:00
- actor: claude-code
  id: 01m4nrvx78esyjvk5t7ehw4m8r
  text: |-
    Implementation landed:
    - New internal type `EmbeddingBatchDivision` (Sources/FoundationModelsExtras/ModelPool/EmbeddingBatchDivision.swift). It sorts the rows by (token count, input index), puts each row in the last sub-batch while (rows + 1) x (row length) <= budget, else starts a new sub-batch, and puts the vectors back in input order with `inInputOrder(_:)`. The budget is `defaultTokenBudget = 16_384` (32 rows of 512 tokens), with a doc comment that tells why.
    - `MLXEmbedding.embed(texts:)` tokenizes one time, divides the rows, and runs the old pad/model/pool steps for each sub-batch in a new private `vectors(of:padToken:in:)`. All in one `container.perform`, thus still one job in the work queue (the card says not to change this).
    - Unit tests: Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchDivisionTests.swift (6 tests). RED was a compile failure (type missing), GREEN 6/6.
    - Integration: `batchVectorEqualsVectorOfTextAlone` now has two arguments (the old 3 texts, and 15 short texts with one long text in the middle). New test `mixedLengthCallIsFasterThanOnePaddedCall` compares the mixed call with one call of 16 copies of the long text (the tensor shape of the old padded call). RED before the change: speedup 1.34 (mixed 1.20 s, padded 1.61 s). GREEN after the change (speedup >= 4).
    - CHANGELOG.md: new entry under Unreleased.
    - Discovery: a stale `OperationsTests.xctest/Contents/MacOS/OperationsTests.cstemp` from an interrupted build made CodeSign fail ("invalid or unsupported format for signature"). Removing the .cstemp file in .build fixed it.
    - The only build warning is "missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS". It is a SwiftPM build-system warning about the mlx-swift dependency bundle, and it was there before this change (also in the IntegrationTests package build).
  timestamp: 2026-10-11T15:21:25.992408+00:00
- actor: claude-code
  id: 01m4nrwf35z2h1yfykw7xra6f2
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/ModelPool/EmbeddingBatchDivision.swift (new), Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift, Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchDivisionTests.swift (new), IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift, CHANGELOG.md. `swift build` OK; `swift test`: 919 tests in 88 suites passed (11 known issues, all from before); `swift test --package-path IntegrationTests`: 35 tests in 9 suites passed. Only warning: the SwiftPM "missing creator for mutated node" of the mlx-swift_Cmlx bundle, from before this change.
    - next: /review
  timestamp: 2026-10-11T15:21:44.293090+00:00
- actor: claude-code
  id: 01m4ns85t9195dphgzrm97b89a
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (82c5791): 1 finding, 1 confirmed, 0 refuted — IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift:68
    - next: Replace the magic numbers in PooledEmbedderIntegrationTests.swift with named constants. Do this in all of the file. Then run the review again.
  timestamp: 2026-10-11T15:28:08.009708+00:00
- actor: claude-code
  id: 01m4ns8j5m1b7fztz552rpfgbd
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files
    - test: green — swift test, 919 passed
    - commit: 82c5791
    - review: findings — IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift:68
  timestamp: 2026-10-11T15:28:20.660608+00:00
- actor: claude-code
  id: 01m4nsg12nvkwn7r56dp42kmyr
  text: |-
    Finding work (code-hygiene/magic-numbers-swift, "Magic numbers should be replaced by named constants."):
    - I ran swiftlint `no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]` (the rule config) on all of PooledEmbedderIntegrationTests.swift. It found only one literal: the `2` in `longIndex = shortCount / 2`.
    - Fix: `MixedLengthTexts` now has two named counts, `shortCountBeforeLong = 7` and `shortCountAfterLong = 8`. `shortCount` is their sum, and `longIndex` is `shortCountBeforeLong`. The texts are the same as before (15 short texts, the long text at index 7).
    - After the edit, swiftlint found 0 violations in the file.
    - `swift test --package-path IntegrationTests --filter PooledEmbedderIntegrationTests`: 7 tests in 2 suites passed. The only build warning is the SwiftPM "missing creator for mutated node" of the mlx-swift_Cmlx bundle, from before this change.
  timestamp: 2026-10-11T15:32:25.301221+00:00
- actor: claude-code
  id: 01m4nsg2rskfk1qa0pv286fcsf
  text: |-
    ### implement — changed
    - evidence: 1 file — IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift. swiftlint no_magic_numbers: 0 violations. swift test --package-path IntegrationTests --filter PooledEmbedderIntegrationTests: 7 tests in 2 suites passed.
    - next: /test, then /review
  timestamp: 2026-10-11T15:32:27.033161+00:00
- actor: claude-code
  id: 01m4nswh4sarm7jfsfrr3gxac1
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (233732d). 0 findings, 0 confirmed, 0 refuted. 1 file reviewed. The prior finding (PooledEmbedderIntegrationTests.swift magic number) is checked.
    - next: none. The task is in done.
  timestamp: 2026-10-11T15:39:14.969129+00:00
- actor: claude-code
  id: 01m4nswsp2ard7d2zpejt1gm58
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file
    - test: green — swift test, 1542 passed
    - commit: 233732d
    - review: clean — 0 findings
  timestamp: 2026-10-11T15:39:23.714223+00:00
position_column: done
position_ordinal: e780
title: Sort embed texts by token count and divide them into sub-batches, so one long text does not pad the short ones
---
## Problem

`MLXEmbedding.embed(texts:)` (`Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`) tokenizes all the texts of one call, and `EmbeddingBatchPadding` pads each row to the length of the longest row. Then the model runs on one tensor of (text count × longest row).

When one text is long and the others are short, all the short rows get the length of the long row. Attention cost increases with the square of the row length. Thus one long text makes the full call very slow, and it can use enough memory to make the machine swap.

The evidence is from FoundationModelsCodeContext. It embeds 32 chunks in each call, in file order. On a Django clone (44,532 chunks) the embedder did 273 chunks in 8 minutes (approximately 55 s for each call of 32), so the SWE-bench run of FoundationModelsACPAgent turned embeddings off (`bench/code-context.config.yaml`, `semanticSearch: false`). The call path is: CodeContext → ACPAgent `ProfileEmbedding` → Router `RoutedEmbedder` → Router `PooledEmbeddingContainer` → Extras `PooledEmbedder` → the work queue of the model → `MLXEmbedding.embed`. Router and ACPAgent only forward the call.

## Decision

Do NOT cut texts with a token limit. The user does not want an arbitrary limit. Each text must be embedded in full.

Put the fix in Extras, in `MLXEmbedding.embed`, because:

- The padding happens there.
- Only this code has the tokenizer, thus only it knows the token counts.
- All callers (CodeContext, the Multitool tool search, the skills search) get the fix with no change.

## Change

In `MLXEmbedding.embed(texts:)`:

1. Tokenize all the texts one time.
2. Sort the rows by token count, and keep the input index of each row.
3. Divide the sorted rows into sub-batches by a token budget: (rows in the sub-batch) × (longest row in the sub-batch) must not be more than the budget. A row that is longer than the budget goes in a sub-batch by itself, in full.
4. For each sub-batch, pad with `EmbeddingBatchPadding`, run the model and pool, as now.
5. Put the vectors back in the order of `texts`.

The budget limits the size of one tensor. It does not cut a text. Make it a named constant with a doc comment that tells why it has its value. A caller does not need to set it.

## Notes

- Each `embed(texts:)` call is one job in the work queue of the model. A large call holds the queue longer, thus a short query embed (for example from `searchCode`) can wait behind an index call. Do not change this in this task. If it becomes a problem, `PooledEmbedder` can send each sub-batch as a separate job.
- Related task in FoundationModelsCodeContext: `^q52tsr9` (embed a summary of each container chunk). After this task, CodeContext can send larger calls, so that the sort has more rows of similar length.

## Acceptance criteria

- [x] `embed(texts:)` returns one vector for each text, in the order of `texts`, for any input order of lengths.
- [x] The vector of a text is the same (within float tolerance) when it is embedded alone and when it is embedded with texts of other lengths.
- [x] A test proves that a long text does not set the padded length of short texts in a different sub-batch (test the division as a pure function, with no model).
- [x] A text longer than the budget is embedded in full, in a sub-batch by itself.
- [x] No text is cut.
- [x] An integration test with the real Qwen3-Embedding-0.6B model embeds a mixed list of short texts and one long text, and the time is much less than one padded call.
- [x] `swift build` and `swift test` pass with no warnings. #model-pool #feature #cross-repo

## Review Findings (2026-10-11 10:24)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `CHANGELOG.md` — no validator matches this file

- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift:68` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
