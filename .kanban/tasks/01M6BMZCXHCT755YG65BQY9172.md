---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: MLXModelLoader uses HubSource for the hub client, the snapshot lookup and the blob size
---
CoreMLModelLoader and HubModelLoader use HubSource for the Hugging Face client, the snapshot folder lookup and the blob size. MLXModelLoader still has its own copy of this code (hubClient, hubHost, snapshotDirectory, blobBytes). Move MLXModelLoader to HubSource and delete the copy. The behavior must not change: the MLXModelLoaderTests must pass as they are, and MLXModelLoaderError keeps its cases.