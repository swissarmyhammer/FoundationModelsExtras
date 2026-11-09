---
assignees:
- claude-code
position_column: done
position_ordinal: ffd880
title: 'GGUF: a drafter and the llama.cpp footprint estimate in LlamaCppModelLoader'
---
FoundationModelsLlamaCpp c4ae2ab (llama-cpp-swift fb9d182) has `drafter:` and `LlamaLanguageModel.footprintBytes(gguf:projector:drafter:options:)`.
- [ ] Remove `drafterNotSupported`. Resolve `key.ref.drafter` (Hub path or local) through GGUFSource/GGUFFileSet and pass its first shard as `drafter:`
- [ ] A drafter that holds no GGUF model fails with `drafterNotGGUF(ref:)`
- [ ] Footprint = `LlamaLanguageModel.footprintBytes` over the cached files of the target and the drafter (the pool measures after the load)
- [ ] Resolve FoundationModelsLlamaCpp at c4ae2ab or later
- [ ] Real-model tests: Qwen3.5-0.8B-Q8_0 with no drafter gives metadata speculativeDecoding == true (MTP); the same model as its own drafter speculates

#gguf