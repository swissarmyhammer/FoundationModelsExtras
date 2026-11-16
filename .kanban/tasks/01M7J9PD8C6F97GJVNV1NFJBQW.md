---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7j9tmasvfny3k4e6q2kch0n
  text: |-
    Research:
    - Upstream `#hubDownloader` (mlx-swift-lm macro) calls `HubClient.downloadSnapshot` of swift-huggingface 0.13.0. Its cache fast path (`cachedSnapshotPath`) works only for a commit revision with saved snapshot metadata. For `main`, or for a fake cache with no metadata, it calls `listFiles` (a request) before it falls back to the cache. Thus offline, the BlobReusingDownloader must not call the upstream download. It gives the cached snapshot itself.
    - Other request sites: `HubModelLoader.paths(of:)` calls `listFiles` when the snapshot is not cached; `GGUFSource.files` calls `listFiles` and the downloader; `ModelStorage.treeMetadata` calls the tree listing. Each must check the offline mode.
    - The MLX speculative drafter and the MLX embedding load use `hub.downloader()`, thus they get the offline mode through the downloader.
    - Plan: `HubSource.offline` (a stored Bool), a pure parser `HubSource.isOffline(given:environment:)`, and `ModelDownloadError.notCachedOffline(repository:revision:)`.
  timestamp: 2026-11-16T13:47:57.657427+00:00
- actor: claude-code
  id: 01m7ja5nbp9n2r54frrq7wkah0
  text: |-
    Implementation done:
    - `HubSource.offline` (Bool). `HubSource.isOffline(given:environment:)` is the pure parser of `HF_HUB_OFFLINE` (1/true/yes/on, no case, white space trimmed). `isOffline(given:)` reads the process environment.
    - `BlobReusingDownloader(offline:)`: offline, it gives the cached snapshot of the revision (the ref file gives the commit). It does not ask for the tree, downloads no file, and does not call the upstream `#hubDownloader`. Not cached: `ModelDownloadError.notCachedOffline(repository:revision:)`.
    - `HubModelLoader.paths(of:)`: offline with no cached files, it throws `notCachedOffline` and does not call `listFiles`.
    - `GGUFSource`: offline, it reads only the cached snapshot. New internal `init(hub:)` for the tests.
    - `ModelStorage.treeMetadata`: offline, it gives only the kept listing.
    - Public inits with `offline: Bool? = nil`: `HubModelLoader(cacheDirectory:tokenProvider:tokenizerLoader:drafterRegistration:gguf:offline:)`, `MLXModelLoader(cacheDirectory:tokenProvider:tokenizerLoader:drafterRegistration:offline:)`, `CoreMLModelLoader(cacheDirectory:tokenProvider:tokenizerLoader:offline:)`, `GGUFSource(cacheDirectory:tokenProvider:offline:)`, `ModelStorage(cacheDirectory:tokenProvider:offline:)`. The GGUF loader given to `HubModelLoader` keeps its own mode; give it a `GGUFSource(..., offline: true)` too.
    - Tests: new `HubOfflineTests.swift` (18 tests, 31 cases). The first RED was a compile failure. Then I removed each offline branch for a short time: each behavior test failed (the stub got requests, or a 404 came back), except the two GGUF tests of a cached snapshot. That path sent no request before this change too.
    - The default `swift format lint` config (2-space indent, 100 columns) is not the config of the project. Its warnings also occur on lines that this change did not touch, thus I did not act on them.
  timestamp: 2026-11-16T13:53:59.158055+00:00
- actor: claude-code
  id: 01m7ja5rjk0jhgxdn6aw7vt37k
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` has no warnings in our sources; `swift test` passed 2644 tests (156 + 40 + 46 + 26 + 401 + 1941 + 34), 0 failures. Files: Sources/FoundationModelsExtras/ModelPool/{HubSource,BlobReusingDownloader,GGUFSource,ModelStorage,HubModelLoader,MLXModelLoader,CoreMLModelLoader,ResumableFileDownload}.swift; Tests/FoundationModelsExtrasTests/ModelPool/{HubOfflineTests (new),HubFixture}.swift
    - next: review. The last acceptance item (tell foundationmodelsrouter-f1 and testudoapp-75) is open for the orchestrator.
  timestamp: 2026-11-16T13:54:02.451348+00:00
position_column: doing
position_ordinal: '8180'
title: 'Offline mode for the hub source: no Hub request, use only the cache (HF_HUB_OFFLINE and an init parameter)'
---
## Defect
Since the cached-blob fix, each MLX and Core ML load first asks the Hub for the commit and the file list (`BlobReusingDownloader.tree(of:revision:)`), even when the snapshot is in the cache. Unit tests of other packages (for example the Router tests with fake cached repos, `FakeHubCache`) now make a real network request, get a 401 or 404, and then fall back to the cache. Unit tests must not reach the network: CI runners and offline Macs, and the result depends on the behavior of the Hub. `ModelStorage` also asks the Hub for a tree listing that is not in its metadata cache.

## What
An offline mode of `HubSource`, as `huggingface_hub` has with `HF_HUB_OFFLINE`:
- The mode is on when the environment variable `HF_HUB_OFFLINE` is `1`, `true`, `yes` or `on` (no case), or when the host gives it. Add an `offline: Bool? = nil` parameter (nil = read the environment) to each public init that makes a `HubSource`: `HubModelLoader`, `MLXModelLoader`, `CoreMLModelLoader`, `GGUFSource(cacheDirectory:tokenProvider:)` and `ModelStorage`. A test turns it on with the parameter, not with the process environment.
- Offline, no code of Extras sends a request to the Hub: `BlobReusingDownloader` skips the tree lookup and the file downloads, and uses the cached snapshot of the revision (the ref file gives the commit). `GGUFSource` uses the cached files, not `listFiles`. `ModelStorage` uses only the cached tree metadata; with none, `totalBytes` is nil and the state comes from the snapshot files.
- Offline, a model that is not in the cache throws a clear error that names the offline mode and the repository (a new case of `ModelDownloadError`, for example `notCachedOffline(repository:revision:)`), not a network error.
- Check that the upstream `#hubDownloader` path also sends no request offline (its cache fast path); if it can send one, do not call it offline.

## Acceptance
- [x] Tests with the `HubStub` that fail on any request: an offline load of a cached snapshot (MLX path through `BlobReusingDownloader`, and GGUF) sends no request and gives the snapshot; an offline `ModelStorage.storageInfo` sends no request.
- [x] A test: offline, a model that is not cached throws the new error.
- [x] A test: `HF_HUB_OFFLINE` parsing (the values above, and off for other values) through a pure function, not the process environment.
- [x] Doc comments of each init describe the parameter.
- [x] `swift test` passes.
- [ ] Tell the Router session (foundationmodelsrouter-f1) and testudoapp-75 how a test turns the mode on. #bug