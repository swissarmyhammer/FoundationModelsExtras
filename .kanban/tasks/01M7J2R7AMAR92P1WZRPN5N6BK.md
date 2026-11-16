---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7j2z12hnq8mydhb8vrrazeh
  text: |-
    Research done.
    - No test of HubModelLoader, GGUFSource or MLXModelLoader stubs the Hub client. They avoid the network with a cached snapshot only. Thus this task adds a stub transport: a URLProtocol in the test target, given to the HubClient through a URLSession. HubSource gets a `session` property (default `URLSession(configuration: .default)`), thus each loader keeps its behavior.
    - `HubClient.listFiles` gives the first page of the tree only. It gives no commit. The resolved commit comes from the refs file of the cache, or from a revision that is a 40-hex commit.
    - swift-huggingface writes `<commit>.json` in `cache.metadataDirectory(repo:kind:)`. The tree metadata of this task goes in a `trees` subfolder of that folder, so the names do not clash.
    - The MLX download patterns of mlx-swift-lm (`modelDownloadPatterns`) are `package` access: `["*.safetensors", "*.json", "*.jinja"]`. The downloader matches a glob with `fnmatch(glob, path, 0)`.
    - An `.incomplete` blob is `blobs/<normalized etag>.incomplete`. The etag of an LFS file is `lfs.oid`, else the git `oid`.
    - An offline listing throws `URLError`. An HTTP status throws `HTTPClientError`.
  timestamp: 2026-11-16T11:48:01.745108+00:00
- actor: claude-code
  id: 01m7j3d6yw6qdk6e038dadhcmf
  text: |-
    Implementation landed (TDD: the test build failed first because `ModelStorage` did not exist; then 23 of 23 new tests passed).
    Final public API:
    - `ModelStorage` (struct, Sendable): `init(cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment)`, `func storageInfo(of refs: [ModelRef]) async throws -> [ModelStorageInfo]` (concurrent, keeps the order of refs), `func storageInfo(of ref: ModelRef) async throws -> ModelStorageInfo`.
    - `ModelStorageInfo` (Sendable, Codable, Equatable): `ref`, `revision: String?`, `files: [String]`, `totalBytes: Int64?`, `presentBytes: Int64`, `diskBytes: Int64`, `state: ModelDiskState`, and a public memberwise init.
    - `ModelDiskState` (Sendable, Codable, Hashable): `complete`, `partial(presentBytes: Int64, totalBytes: Int64?)`, `missing`. `totalBytes` of `partial` is optional, because an offline call with no cached metadata can find a GGUF split set that misses a shard.
    - `ModelStorageError` (new, public): `invalidRepository(ref:)`, `unknownFileSize(path:)`.
    Decisions:
    - The metadata file is `<cache>/.metadata/models--<owner>--<name>/trees/<commit>.json`. When the cache names no commit, the key is the requested ref (for example `main`), percent-encoded.
    - `revision` is the commit from the refs file of the cache, or the revision when it is a 40-hex commit, else `nil`.
    - Only a `URLError` of the listing counts as offline. An HTTP error (401, 404) of the listing is thrown.
    - A file is present when the snapshot links it, or when the cache holds `blobs/<etag>`; else its `blobs/<etag>.incomplete` blob counts as partial bytes.
    - `diskBytes` is the allocated size of each blob, and a shared blob counts one time.
    - A Core ML repository gives the file set of an embedding load. The MTP drafter is not part of the file set of a ref.
    - `GGUFFileSet` got an internal `select(from:under:allowsMissingShards:)`. `MLXModelLoader` got an internal `downloadPatterns`. `HubSource` got a `session` property, which a test gives a stub.
    The acceptance item "Send the final API names to the testudoapp-75 session" is not done by this step: the names are in the reply to the caller, which relays them.
  timestamp: 2026-11-16T11:55:46.524599+00:00
- actor: claude-code
  id: 01m7j3d9ykbnf6fcemy80mkfpq
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsExtras/ModelPool/{ModelStorage.swift, ModelStorageInfo.swift, HubTreeMetadata.swift} (new), {HubSource.swift, GGUFFileSet.swift, MLXModelLoader.swift} (changed), Tests/FoundationModelsExtrasTests/ModelPool/{ModelStorageTests.swift, HubStub.swift} (new). `swift test`: 23/23 new ModelStorageTests pass; full run 2542 tests pass (156+40+46+26+401+1885+34 in 7 runs), 0 failures, 0 warnings.
    - next: /review. The caller must relay the API names to the testudoapp-75 session.
  timestamp: 2026-11-16T11:55:49.587159+00:00
- actor: claude-code
  id: 01m7j3nqy2jd20zt2q8qgwrkcm
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 5bd1c9b). 0 findings, 0 confirmed, 2 refuted. 8 files reviewed. 6 .kanban files not reviewed (ignore rule).
    - next: The task is in done. The acceptance item "Send the final API names to the testudoapp-75 session" is not checked. The implementer must do this step.
  timestamp: 2026-11-16T12:00:26.050917+00:00
- actor: claude-code
  id: 01m7j3p3xxxp66swknkh55er18
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files (ModelStorage, ModelStorageInfo, HubTreeMetadata, HubStub, ModelStorageTests; HubSource, GGUFFileSet, MLXModelLoader changed)
    - test: green — swift test, 2588 passed, 0 failed, 0 skipped
    - commit: 5bd1c9b
    - review: clean — 0 findings
    - The orchestrator sends the final API names to the testudoapp-75 session after the push.
  timestamp: 2026-11-16T12:00:38.333364+00:00
position_column: done
position_ordinal: ffe780
title: 'Model storage API: download size and disk state of models, with no download'
---
## Why
The TestudoApp Settings window needs a Models pane (TestudoApp task ^453zgr3, Step 2, D183/D184). Before the first download (21.7 GB for the default models), the user must see each model, its download size and its disk state. No package gives these data before a download now. The Router adds the slot choices (main, small, embedding, decision) on top of this API, and the settings `models` endpoint gives the data to the pane (D100 (d)).

## What
A public API in `Sources/FoundationModelsExtras/ModelPool/`. It starts no download and loads no model. Proposed names (change them only for a good reason, and report the final names):

- `ModelStorage` (a struct over the `HubSource` cache and token provider, made like `HubModelLoader`): `func storageInfo(of refs: [ModelRef]) async throws -> [ModelStorageInfo]` and `func storageInfo(of ref: ModelRef) async throws -> ModelStorageInfo`.
- `ModelStorageInfo` (`Sendable`, `Codable`, `Equatable`): `ref`, `revision` (the resolved commit when known), `files` (the relative paths of the file set), `totalBytes: Int64?` (the sum of the sizes of the file set; `nil` when the metadata is not available, for example offline with no cached metadata), `presentBytes: Int64` (the bytes of the file set that are in the cache, complete blobs plus `.incomplete` blobs), `diskBytes: Int64` (the bytes that the blobs of the file set use on disk), and `state: ModelDiskState`.
- `ModelDiskState`: `complete`, `partial(presentBytes:totalBytes:)`, `missing`.

The file set of a ref is the same set that a load downloads: use the format detection of `HubModelLoader` (`format(of:)`, `paths(of:)`), the MLX patterns of `MLXModelLoader`, and `GGUFFileSet` for a GGUF ref (a quant path or shards). A local folder ref (`ModelRef.localDirectory`) is `complete`, and its size is the size of its files.

Sizes come from the Hub metadata of the revision: `HubClient.listFiles(in:kind:revision:recursive:)`, with `Git.TreeEntry.effectiveSize`. Cache the metadata on disk (one JSON file for each repo and commit, in the hub cache or next to it). A second call reads the cache and makes no network request. Offline, a call uses the cached metadata. With no cached metadata and no network, `totalBytes` is `nil` and the state comes from the files in the snapshot.

The disk state reads `~/.cache/huggingface/hub` (the `HubCache` of the source): the snapshot links, the blobs, and the `<etag>.incomplete` blobs.

## Acceptance
- [x] The types and the methods above are public, with doc comments.
- [x] A call makes no download and loads no model: a stub transport sees only the tree listing request, and a second call sees no request.
- [x] Tests with a temporary hub cache folder cover `complete`, `partial` (an `.incomplete` blob and a missing shard), `missing`, a local folder ref, a GGUF quant ref, and an offline call with and with no cached metadata.
- [x] `swift test` passes.
- [x] Send the final API names to the testudoapp-75 session. #feature