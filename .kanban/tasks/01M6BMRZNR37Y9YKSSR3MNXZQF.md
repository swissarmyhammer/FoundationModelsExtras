---
comments:
- actor: claude-code
  id: 01m6bywygw322q240s5tgs6rky
  text: |-
    ### implement — changed
    - evidence: swift test exit 0, 1642 + 401 tests pass. New suite LocalModelPathTests (10 tests; red was a compile failure on the missing ModelRef.localDirectory).
    - files: Sources/FoundationModelsExtras/ModelPool/{ModelRef,HubModelLoader,MLXModelLoader,CoreMLModelLoader,CoreMLEmbedding,CoreMLPackage}.swift, Tests/FoundationModelsExtrasTests/ModelPool/LocalModelPathTests.swift, docs/REFERENCE.md
    - design choice: a reference is local when its repo string is the path of an existing directory (as the card says). A Hub name that equals a folder relative to the working directory would load as local. A path with an @ splits as a revision.
    - Core ML compiled cache for a local folder is keyed by path plus manifest mtime.
    - Router tests use Hub names only; no old-behavior expectation found.
    - next: /review
  timestamp: 2026-11-01T16:25:50.876749+00:00
position_column: doing
position_ordinal: '80'
title: HubModelLoader detects the model format from a local path
---
The agent config must accept a local path as a model reference and find the format by itself: a .mlpackage folder is CoreML, safetensors files are MLX. HubModelFormat.detect works on the files of a Hub repository only. HubModelLoader.format(of:) looks in the Hub cache or asks the Hub. Add a local-path branch: when the reference is an existing directory, list its top-level names and call HubModelFormat.detect. Make MLXModelLoader and CoreMLModelLoader load from that directory with no download. Add tests for a CoreML folder, an MLX folder, and a folder with both. Coordinated with: FoundationModelsRouter ^y18w1dp (ModelRef accepts a local model path), FoundationModelsRouter ^zpcsp86 (LiveModelLoader uses HubModelLoader), FoundationModelsACPAgent ^gsxzx6h (default embedding and config path).