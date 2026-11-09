---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'GGUF: load one real split set from its first shard'
---
Once FoundationModelsLlamaCpp confirms that loading from the first shard of a split set works, add a gated real-model test that loads a small split-set GGUF through the pool (download of every shard, footprint, one answer).

#gguf