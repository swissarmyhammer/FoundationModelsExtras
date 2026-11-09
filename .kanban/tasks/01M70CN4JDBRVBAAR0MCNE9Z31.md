---
assignees:
- claude-code
depends_on:
- 01M70CN1WSVN7TXMT9BJ44S9FR
- 01M70CMZ5CMP5SA2YHXT59YKYT
position_column: todo
position_ordinal: '8380'
title: 'GGUF: LlamaCppModelLoader for the .llm role, footprint'
---
- [ ] `LlamaCppModelLoader` builds `LlamaLanguageModel(gguf: firstShard, projector:, options:)` for `.llm`; wire `drafter:` when foundationmodelsllamacpp-f1 lands it
- [ ] `.embedding` with GGUF fails with a clear error
- [ ] Evict releases the model
- [ ] footprintBytes: sum of every shard + projector + drafter, until LlamaCpp ships `LlamaLanguageModel.footprintBytes(gguf:projector:drafter:options:)`
- [ ] Hermetic tests with the vocab-only GGUFs of LlamaCppTestFixtures; one real-model integration test with a small single-file GGUF (split sets not yet confirmed by LlamaCpp) #gguf