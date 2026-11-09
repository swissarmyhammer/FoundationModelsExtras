---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'GGUF: wire the drafter and the LlamaCpp footprint helper when they land'
---
Blocked on FoundationModelsLlamaCpp (foundationmodelsllamacpp-f1) pushing to main:
- [ ] `LlamaLanguageModel(gguf:projector:drafter:options:)`: resolve `key.ref.drafter` through GGUFSource and pass its model file. Remove `LlamaCppModelLoaderError.drafterNotSupported`.
- [ ] Footprint: add the drafter files, then switch to `LlamaLanguageModel.footprintBytes(gguf:projector:drafter:options:)` when it lands
- [ ] Load one real split set once LlamaCpp confirms that loading from the first shard works

#gguf