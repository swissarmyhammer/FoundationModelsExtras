---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6bxw4v3d5s37r2wqn9w2kqf
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift. MLXModelLoader now holds a HubSource. hubClient(), the snapshot lookup and the blob size use it. The copies of hubHost, the endpoint variable, the cache field and the token provider field are deleted. MLXModelLoaderError keeps its cases. MLXModelLoaderTests are unchanged. 81 tests in MLXModelLoaderTests, CoreMLModelLoaderTests and HubModelLoaderTests pass.
    - note: One edge changed. A revision that is not a valid path part gave a thrown path error before. It now gives notInCache, as CoreMLModelLoader already does. No test covers it.
    - next: review
  timestamp: 2026-11-01T16:07:56.003604+00:00
position_column: doing
position_ordinal: '80'
title: MLXModelLoader uses HubSource for the hub client, the snapshot lookup and the blob size
---
CoreMLModelLoader and HubModelLoader use HubSource for the Hugging Face client, the snapshot folder lookup and the blob size. MLXModelLoader still has its own copy of this code (hubClient, hubHost, snapshotDirectory, blobBytes). Move MLXModelLoader to HubSource and delete the copy. The behavior must not change: the MLXModelLoaderTests must pass as they are, and MLXModelLoaderError keeps its cases.