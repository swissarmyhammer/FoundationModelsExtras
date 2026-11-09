---
assignees:
- claude-code
position_column: done
position_ordinal: ffd980
title: 'Pool: a context size per load for GGUF models'
---
Approved by foundationmodelsrouter-4b.
- [ ] `ModelPoolKey(ref:role:contextSize: Int? = nil)`
- [ ] `PooledModelLoader.poolKey(for:)`; the default drops the context. HubModelLoader keeps it for GGUF only (delegates to the GGUF loader), and caches the format per ref. LlamaCppModelLoader maps nil to `options.contextSize`.
- [ ] The pool normalizes the key at each acquire. A resident key of the same ref + role whose context is at least the requested one gives the hold (the smallest such); the model is never reloaded in place. `ModelHold.key` is the resident key.
- [ ] LlamaCppModelLoader loads and measures at `key.contextSize`; `options` is public (maxLiveSequences, kvCacheType)
- [ ] `PooledModel(ref:pool:contextSize:)`, plus a way to read the key the model loaded with
- [ ] Docs

#gguf #model-pool