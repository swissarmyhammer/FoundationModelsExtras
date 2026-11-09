---
assignees:
- claude-code
depends_on:
- 01M70CMX2F2K08VK2016HQ4EC8
position_column: todo
position_ordinal: '8280'
title: 'GGUF: HubModelFormat.gguf detection and path-scoped download'
---
- [ ] `HubModelFormat.gguf`, chosen from the files under `ModelRef.path` (or the repo root): `.gguf` files that are not `mmproj*.gguf`
- [ ] Choose the model: a single file; a folder with one GGUF, or the first shard `*-00001-of-0000N.gguf` of one split set; more than one distinct model fails with an error that lists the choices
- [ ] `mmproj*.gguf` beside the model is the projector, not a model and not a shard
- [ ] Download only the files under the path plus the projector, with progress through ModelLoadProgress
- [ ] Format decision for `.llm` keys too (today `.llm` is always MLX)
- [ ] Hermetic tests on path lists; local folder tests #gguf