---
position_column: todo
position_ordinal: '80'
title: HubModelLoader detects the model format from a local path
---
The agent config must accept a local path as a model reference and find the format by itself: a .mlpackage folder is CoreML, safetensors files are MLX. HubModelFormat.detect works on the files of a Hub repository only. HubModelLoader.format(of:) looks in the Hub cache or asks the Hub. Add a local-path branch: when the reference is an existing directory, list its top-level names and call HubModelFormat.detect. Make MLXModelLoader and CoreMLModelLoader load from that directory with no download. Add tests for a CoreML folder, an MLX folder, and a folder with both. Router ModelRef must accept the path too; that is a separate Router card.