---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7mn1y42s4vemc20181qvtd3
  text: |-
    Router confirmed the plan. LiveModelLoader builds a HubModelLoader, so HubModelLoader forwarding is required, not optional. KV scaling stays in the Router (Footprint.kvBytes → sessionBytes).
    Upstream: mlx-swift-lm card ^4zv2rdx, queued behind its fused quantized-attention kernel (^6xcb05k). Expect a wait.
    Test constructor: `KVCacheConfiguration(strategy: .affine(try AffineKVCacheConfiguration(bits: 8, groupSize: 64)))`.
    The Router will forward the stable SHA if it arrives there first.
  timestamp: 2026-11-17T11:42:40.258840+00:00
- actor: claude-code
  id: 01m7mr33wc31zfywt43y93zt66
  text: 'After pull 4400408: both MLXModelLoader inits and HubModelLoader.init now end with `offline:`. Add `kvCache:` after it, and forward it to the inner MLXModelLoader alongside `offline`.'
  timestamp: 2026-11-17T12:35:44.652957+00:00
- actor: claude-code
  id: 01m7mr4bkevz629t1c0y0t44ts
  text: |-
    ### implement — stuck
    - evidence: `git ls-remote mlx-swift-lm stable` → 87460a3 (unchanged). A shallow clone of stable has no `kvCache` in Libraries/MLXFoundationModels, so `MLXLanguageModel(... kvCache:)` does not exist and the change cannot compile. Upstream ^4zv2rdx is queued behind ^6xcb05k.
    - next: when the Router or mlx-swift-lm-fb sends the stable SHA, run `swift package update mlx-swift-lm`, then `/finish ^cbhcf4v`.
  timestamp: 2026-11-17T12:36:25.326856+00:00
- actor: claude-code
  id: 01m7mzadfgjnem7aj4j8zcv9w1
  text: 'Unblocked: mlx-swift-lm origin/stable at 59a2ec21 has `MLXLanguageModel.init(..., kvCache: KVCacheConfiguration? = nil)` on the progress initializer (the one taking a load closure, as used in loadLanguageModel). `MLXLanguageModel.kvCache` is a public `let`, so a test can read it back. Prompt caches are keyed by the configuration. `AffineKVCacheConfiguration.eightBit` and `.fourBit` exist as statics. First run `swift package update mlx-swift-lm` so Package.resolved points at 59a2ec21.'
  timestamp: 2026-11-17T14:42:03.888610+00:00
- actor: claude-code
  id: 01m7mzd697vzj6r9nfc8s9b004
  text: |-
    Picked up. `swift package update mlx-swift-lm` resolved stable at 59a2ec21 (Package.resolved is gitignored in this repo, so the pin is local only; CI resolves the branch head). The progress init of MLXLanguageModel takes `kvCache:` after `prefillStepSize:` and before `weightsLocation:`; `MLXLanguageModel.kvCache` is a public let. KVCacheConfiguration and AffineKVCacheConfiguration are Hashable; `AffineKVCacheConfiguration.eightBit` is bits 8, group 64.
    Coordinator added a requirement from the Router: HubModelLoader exposes `public let kvCache: KVCacheConfiguration?` (readable like LlamaCppModelLoader.options), MLXModelLoader the same, plus a test that `HubModelLoader(kvCache: 8-bit affine group 64).kvCache == the value`.
    Seam plan: split `loadLanguageModel` into an internal `makeLanguageModel(for:downloader:)` that builds the MLXLanguageModel (no preload, no weights) and the preload step; a unit test reads `.kvCache` off the built model. HubModelLoader's `mlx` becomes internal so a test can check forwarding.
  timestamp: 2026-11-17T14:43:34.823449+00:00
- actor: claude-code
  id: 01m7mzs7f56g0y3tar5j1m41g8
  text: |-
    Implementation landed (not committed).
    - MLXModelLoader: both inits end with `kvCache: KVCacheConfiguration? = nil` after `offline:`; stored as `public let kvCache`. `loadLanguageModel` is split into the internal seam `makeLanguageModel(for:downloader:)` (builds the MLXLanguageModel with `kvCache:`, loads no weights) and a private `preload(_:)` (the preload span).
    - HubModelLoader: `public let kvCache` (Router's added requirement), init takes `kvCache:` last and forwards it to the inner MLXModelLoader. `mlx` went from private to internal so a test can check forwarding.
    - Discovery: 59a2ec21 also changed `MLXLanguageModel.ProgressContainerLoader`: the closure now gets `LoadProgressHandlers`, not a `(Progress) -> Void`, so the call is now `loadModelContainer(..., progress: progress)`, which forwards both download and weights progress. The old `progressHandler:` call does not compile against 59a2ec21, so any consumer pinning this stable needs the same change.
    - Package.resolved is gitignored (root and IntegrationTests). Both were updated locally to 59a2ec21. The IntegrationTests package builds clean.
    - Tests (TDD, RED was a compile failure on the missing members): KVCacheFixture.swift (8-bit affine, group 64); MLXModelLoaderTests: keeps the given kvCache, nil by default, the built model's `.kvCache` equals it; HubModelLoaderTests: `.kvCache` equals the given value, `mlx.kvCache` equals it (forwarding), nil by default.
  timestamp: 2026-11-17T14:50:09.253473+00:00
- actor: claude-code
  id: 01m7mzsb2v0k88eqvq36yagj86
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift, Sources/FoundationModelsExtras/ModelPool/HubModelLoader.swift, Tests/FoundationModelsExtrasTests/ModelPool/KVCacheFixture.swift (new), Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/HubModelLoaderTests.swift. `swift test`: 2739 tests passed, 0 failed (180+43+46+26+451+1958+35); only the allowed `missing creator … mlx-swift_Cmlx.bundle` warning. `swift build --build-tests --package-path IntegrationTests` clean.
    - next: /review ^cbhcf4v, then commit; after the push, message foundationmodelsrouter-4c with the SHA.
  timestamp: 2026-11-17T14:50:12.955125+00:00
- actor: claude-code
  id: 01m7mzvaqvzjm4ddzfvn7qnr5d
  text: |-
    ### test — green
    - evidence: swift test on the uncommitted working tree, exit 0, 0 failures, 0 skipped; the six new kvCache tests (MLXModelLoader x3, HubModelLoader x3) passed; the only warning is the allowed "missing creator for mutated node ... mlx-swift_Cmlx.bundle"
    - next: review
  timestamp: 2026-11-17T14:51:18.139225+00:00
position_column: doing
position_ordinal: '8180'
title: MLXModelLoader and HubModelLoader take a KV-cache configuration (kvCache)
---
Requested by FoundationModelsRouter (Router card ^2fet0gs), so ACPAgent can set profile.kvBits for every model.

Blocked on mlx-swift-lm: `MLXLanguageModel` gains `kvCache: KVCacheConfiguration? = nil` (being done in mlx-swift-lm-fb). Wait for the stable SHA, then `swift package update mlx-swift-lm`.

## Change
- `MLXModelLoader.init(... kvCache: KVCacheConfiguration? = nil)` (public and internal `cache:` init), store it, and pass it to `MLXLanguageModel(...)` in `loadLanguageModel` (Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift ~327). nil means no change.
- `HubModelLoader.init` takes the same `kvCache` and forwards it to its inner `MLXModelLoader`, because the Router may load through HubModelLoader.
- Doc comments match the surrounding style.

## TDD
- A test that a loader built with `kvCache:` exposes/forwards that configuration to the model it builds (e.g. an internal `kvCache` property, or a `makeLanguageModel` seam checked without loading weights), and that the default is nil.
- The same for HubModelLoader forwarding.

## Notes
- Footprint: `footprintBytes` counts only weight files. KV/session bytes come from the caller through `ModelPool.acquire(_:footprintBytes:sessionBytes:loader:)`, so the KV size of a quantized cache is the Router's to work out. Nothing in Extras does KV sizing.
- LlamaCppModelLoader already takes `LlamaLanguageModel.Options.kvCacheType`. No change.
- When done, message the Router session (foundationmodelsrouter-4c) with the pushed SHA.