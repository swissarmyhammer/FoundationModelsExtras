---
comments:
- actor: wballard
  id: 01m5pvr0vz0eqcg416a1dtzm3w
  text: 'Done. ModelRef.init(repo:revision:) and init(_:) normalize nil/""/"main" to nil; init(_:) and Codable decode go through init(repo:revision:). MLXModelLoader.defaultRevision now reads ModelRef.defaultRevision, so a nil revision still asks the Hub for main. ModelPoolKey: no change (it holds the ModelRef; synthesized Hashable). Tests: ModelRefTests (parameterized forms, Codable, real revision), ModelPoolTests.unpinnedAndMainRevisionShareOneLoad. swift test: 2215 tests pass, 0 failures.'
  timestamp: 2026-10-24T11:46:40.639945+00:00
position_column: done
position_ordinal: ffc580
title: Treat a ModelRef with no revision and with revision main as one pool key
---
## What

A `ModelRef` with no revision and the same `ModelRef` with revision `main` are two `ModelPoolKey`s today. So the pool can load the same weights two times, with two `GenerationQueue`s. The pool exists to stop that: one load and one queue for each model.

- `Sources/FoundationModelsExtras/ModelPool/ModelRef.swift`: `init(_ string:)` and `init(repo:revision:)` keep `revision` as given. Normalize in the initializers: store `nil` for `"main"` and for `""` (`"org/repo@"`). Then equality, hashing and `stringValue` see one form. Check that the downloader still asks for `main` when the revision is `nil`.
- Codable: a decoded `ModelRef` goes through the same normalization.
- Note in the commit body: after this change, `"x@main"` shows as `"x"` in recorded transcripts and in metric labels.
- `Sources/FoundationModelsExtras/ModelPool/ModelPoolKey.swift`: no change is expected, because it holds the `ModelRef`. Confirm it.

Found by a read of the pool on 2026-10-24 (bench24-1023b follow-up). The rest of the pool is correct: `ModelPoolKey` is `ref` plus `role`, `admit` runs loads in series (a late second request gets `.lateHit`), and each pool entry owns one `GenerationQueue` (`ModelPool.swift:20-23, 427-428, 577-594`).

## Acceptance Criteria

- [ ] `ModelRef("org/repo") == ModelRef("org/repo@main")`, `ModelRef("org/repo@")` is equal to both, and the three have the same hash and the same `stringValue`.
- [ ] A Codable round trip of `"org/repo@main"` gives a value equal to `ModelRef("org/repo")`.
- [ ] Two acquires of `ModelPoolKey(ref: "org/repo", role: .llm)` and `ModelPoolKey(ref: "org/repo@main", role: .llm)` load the model one time (one loader call), and the two holds give the same container instance (`===`). Do not assert on the per-model queue: a later task deletes it.
- [ ] `ModelRef("org/repo@abc123")` stays different from `ModelRef("org/repo")`.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/ModelRefTests.swift` (create it, or add to the present tests of `ModelRef`): equality, hash, `stringValue` and the Codable round trip for `nil`, `""`, `"main"` and a real revision.
- [ ] A pool test with a stub loader (the shape of the present `ModelPool` tests): the two keys above give one load (the count of loader calls is 1) and the same container (`===`).
- [ ] `swift test` in FoundationModelsExtras: all tests pass, with no new warnings.

## Workflow

- Use `/tdd`: write the failing tests first, then implement until they pass.