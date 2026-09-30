---
position_column: todo
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
- [ ] `MLXModelLoader(tokenizerLoader: custom)` loads each model with `custom`.
- [ ] `MLXModelLoader()` behaves as now.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift`: a recording tokenizer loader is used for a load (a unit test with a stub, if the load can run without weights; else in IntegrationTests).
- [ ] `IntegrationTests/`: a real load with a wrapping tokenizer loader records one call.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool