---
comments:
- actor: claude-code
  id: 01m3rq6s85tqjvdsrgqmtf8ydd
  text: |-
    Research done.
    - `TokenizerLoader` is `MLXLMCommon.TokenizerLoader` (one method: `load(from: URL)`). The loader uses `#huggingFaceTokenizerLoader()` in two places: `loadLanguageModel` (LLM) and `MLXEmbedding.load` (embedding).
    - A unit test cannot run a load without weights: `load(key:progressHandler:)` makes `#hubDownloader()` for each call, and the LLM and embedding factories read `config.json` and the weight files. Thus the load test goes in IntegrationTests. The unit test checks that the loader keeps the given tokenizer loader.
    - The IntegrationTests package does not name `MLXLMCommon`, `MLXHuggingFace` or `Tokenizers`. The wrapping tokenizer loader of the integration test needs `#huggingFaceTokenizerLoader()`, which expands to `Tokenizers.AutoTokenizer`. Thus the integration package gets these products.
    - `MLXLanguageModel` keeps one model cache for each process. A load of a model that is in that cache calls no tokenizer loader. The integration test evicts each model that it loads.
  timestamp: 2026-09-30T08:34:26.693590+00:00
- actor: claude-code
  id: 01m3rqw74xdaz5hzygsv6dr2nn
  text: |-
    Implementation done.
    - `MLXModelLoader` keeps `tokenizerLoader: any TokenizerLoader` (internal, for the unit test). `init(tokenizerLoader:)` is public. `nil` gives `#huggingFaceTokenizerLoader()`. `loadLanguageModel(configuration:downloader:tokenizerLoader:)` and `MLXEmbedding.load(configuration:downloader:tokenizerLoader:)` use it. The first argument of each of these private helpers now has a label (swift/fluent-usage).
    - RED: the unit test did not compile ("argument passed to call that takes no arguments"). GREEN: 11 of 11 tests of `MLXModelLoaderTests` pass.
    - Integration: new `RecordingTokenizerLoader` (Support) wraps `#huggingFaceTokenizerLoader()` and records each folder in an `EventLog<URL>`. New suite `MLXModelLoaderIntegrationTests` loads the real LLM and the real embedding model through `ModelPool(loader: MLXModelLoader(tokenizerLoader:))`, and expects one tokenizer load for each model. Both cases pass.
    - The integration package names `MLXLMCommon`, `MLXHuggingFace` and `Tokenizers` (swift-transformers) again, because the new test file imports them. `Package.resolved` of the integration package did not change.
    - Discovery: in a file that imports `Tokenizers` and `MLXLMCommon`, the name `Tokenizer` is ambiguous. Write `MLXLMCommon.Tokenizer`.
    - README and CHANGELOG document the parameter.
    - The push to origin main and the message to the Router session are for the orchestrator.
  timestamp: 2026-09-30T08:46:09.053024+00:00
- actor: claude-code
  id: 01m3rqwa5zv0n3ycshcbgfs7c0
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift, Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift, IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/MLXModelLoaderIntegrationTests.swift (new), IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/RecordingTokenizerLoader.swift (new), README.md, CHANGELOG.md. `swift test`: 851 tests in 83 suites pass (4 known issues from TelemetryCaptureTests, from before this change). `swift test --package-path IntegrationTests`: 32 tests in 9 suites pass. No new warnings.
    - next: review. The item "CI is green on the pushed commit" stays open until the orchestrator pushes.
  timestamp: 2026-09-30T08:46:12.159652+00:00
position_column: doing
position_ordinal: '8180'
title: MLXModelLoader takes an optional tokenizer loader
---
## What
The Router test support (`RealModelContainer`) still makes its own `MLXLanguageModel`, because it loads chat templates with a pinned date through its own tokenizer loader, and `MLXModelLoader` takes none. With this parameter, no package outside Extras needs to make an `MLXLanguageModel`.

```swift
public init(tokenizerLoader: (any TokenizerLoader)? = nil)   // nil = #huggingFaceTokenizerLoader()
```

- `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`: store the tokenizer loader and use it for both roles.
- `README.md`: the parameter.
- Push to `origin main` when green, and tell the Router session (foundationmodelsrouter-d5) the revision.

## Acceptance Criteria
- [x] `MLXModelLoader(tokenizerLoader: custom)` loads each model with `custom`.
- [x] `MLXModelLoader()` behaves as now.
- [ ] CI is green on the pushed commit.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift`: a recording tokenizer loader is used for a load (a unit test with a stub, if the load can run without weights; else in IntegrationTests).
- [x] `IntegrationTests/`: a real load with a wrapping tokenizer loader records one call.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool