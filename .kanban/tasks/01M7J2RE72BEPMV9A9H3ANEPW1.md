---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7j439c0s16mrtxj2aygmmnq
  text: |-
    ## Cause (research)

    Probes against the real Hub, with an APFS clone of the local cache of `mlx-community/Qwen3.8-27B-4bit` (refs/main = 10c35ca, blobs = the sha256 of the shards; the Hub main is now b935172 with the same LFS hashes):

    1. Revision `main` with the old ref: the upstream makes only the tree request. `cachedFilePath(revision: "main")` resolves the OLD ref and gives the OLD snapshot. No download, but the result is the stale revision A. When B has a file that A does not have, that one file downloads, `storeFile(ref: "main")` moves refs/main to B in the middle of the snapshot, and the files that the fast path already gave from A are not linked into B (snapshot B is incomplete).
    2. Revision = commit B: one HEAD per file (13 HEADs), then each blob is linked. No GET. Thus the upstream CAN reuse a blob, but only through the HEAD preflight.
    3. Revision = commit B, and each HEAD fails: the upstream does a full GET of each file (5 GB for each shard), although `blobs/<sha256>` is present.

    The exact cause: `HubClient.downloadFile` finds a cached blob only by the per-file HEAD preflight (`fetchFileMetadata`, wrapped in `try?`). It never uses the hashes of the tree listing that `downloadSnapshot` already has. When the HEAD fails or gives no `X-Linked-Etag`/`ETag` (transient error, rate limit, a proxy or `HF_ENDPOINT` mirror), `preflightMetadata` is nil, and the code takes the "generic non-ETag fallback path": a full GET of the file, and `storeFile` then discards the bytes because the blob exists. The fast path is per commit snapshot (`cachedSnapshotPath` needs `<commit>.json` metadata; `cachedFilePath` needs the snapshot link), never per blob. I could not reproduce the exact HEAD failure of the manual run of the user; the real Hub answered each HEAD in the probes.

    ## Fix plan
    A downloader in Extras between the loaders and `#hubDownloader`: resolve the revision to its commit (`getModel(revision:).sha`), list the tree at that commit, link each matching file whose blob (`lfs.oid ?? oid`) is in `blobs/` into `snapshots/<commit>/` with `HubCache.storeFile`, then run the upstream download at the commit and write the ref. A linked file then needs no HEAD and no GET. When the Hub cannot be reached, the upstream download runs as before (it falls back to the cache). MLX (model and drafter), Core ML and GGUF all use it through `HubSource`.
  timestamp: 2026-11-16T12:07:49.888885+00:00
- actor: claude-code
  id: 01m7j4eq81d7nqs5sxxjwwcjzc
  text: |-
    ## Implementation landed
    - New `BlobReusingDownloader` (Sources/FoundationModelsExtras/ModelPool/BlobReusingDownloader.swift): it gets the commit of the revision (`getModel(revision:).sha`, or the revision when it is a commit) and the tree listing of that commit. For each file of the patterns whose blob (`lfs.oid ?? oid`, through `HubTreeMetadata`) is in `blobs/` and has no snapshot link, it calls `HubCache.storeFile` (the blob copy is skipped, only the link is made). Then it runs the upstream download at the commit, and writes the ref file of a revision that is not a commit. When the Hub gives no commit or no listing (no network), the upstream runs for the revision as is (it falls back to the cache). Cancellation still throws.
    - `HubSource.downloader()` makes it over `#hubDownloader(client)`. MLX (model and MTP drafter), Core ML and GGUF all use `hub.downloader()` now.
    - `HubSource.isCommit(_:)` and `HubSource.paths(_:matching:)` are shared with `ModelStorage` (its own commit check and fnmatch filter moved there).
    - Tests: `HubStub` has a new answer `.repository(commit:files:)` that answers the model information, the tree listing, and `HEAD`/`GET` of each file with `X-Repo-Commit` and `X-Linked-Etag`/`ETag`. `HubFixture` moved from ModelStorageTests.swift to its own file. New suite HubSourceDownloaderTests (7 tests).
    - RED before the fix: 4 of 6 failed for the expected reasons (13-style HEAD file requests for commit B; main stayed at the old commit; the ref was not moved; the snapshot of B missed the reused file beside a new file — an upstream bug of a stale ref). 2 passed already (link through HEAD, new hash downloads): regression guards. The offline test was checked to fail when the fallback is removed.
    - Behavior change: a download of `main` after main moved on the Hub now gives the new commit (as `huggingface_hub` does), not the stale cached snapshot.

    ### implement — changed
    - evidence: `swift test` exit 0, all suites pass (1892 + 401 + 156 + 46 + 40 + 34 + 26 tests), no warnings in our sources. Files: BlobReusingDownloader.swift (new), HubSource.swift, MLXModelLoader.swift, CoreMLModelLoader.swift, GGUFSource.swift, ModelStorage.swift, HubStub.swift, HubFixture.swift (new), ModelStorageTests.swift, HubSourceDownloaderTests.swift (new)
    - next: /review
  timestamp: 2026-11-16T12:14:04.545301+00:00
position_column: doing
position_ordinal: '8180'
title: 'Download: reuse cached blobs with the same hash after a revision change'
---
## Defect
In a manual test of the user, the cache already had 16 GB of `mlx-community/Qwen3.8-27B-4bit` shards. After the revision of the repo changed, the downloader got all the shards again. `huggingface_hub` reuses a blob with the same hash: the blob name is the etag (the sha256 of an LFS file), and the new snapshot only links to it.

## Where
The downloads go through `#hubDownloader(hubClient())` in `MLXModelLoader.swift:154` and `CoreMLModelLoader.swift:116`, wrapped in `ProgressReportingDownloader`, and through `GGUFSource.swift:98`. The download code is in the `swift-huggingface` package (0.13.0): `HubClient+Files.swift` `downloadSnapshot` (line ~1588) and `downloadFile` (line ~551), and `HubCache.swift` (`cachedFilePath`, `cachedBlobPath(repo:kind:etag:)`, `blobPath`). `downloadSnapshot` has a fast path only for a snapshot of the same commit. Find the exact cause first (for example: the check is per commit snapshot and not per blob, or the Xet transport writes a blob under another name). Write the cause in a comment on this task.

## Fix
Fix it in Extras, not in the upstream package. For example: before the upstream download, list the files of the new revision (`listFiles`), and for each file whose blob is already in `blobs/` (the LFS sha256 or the etag, normalized as `HubCache` does), make the snapshot link of the new commit (and the ref file) so the upstream download finds the file in the cache. All three download paths (MLX, Core ML, GGUF) must get the fix.

## Acceptance
- [x] A regression test with a temporary hub cache: the blobs of revision A are present, revision B lists the same hashes, and the download of B makes no file request (a stub transport counts the requests) and gives a snapshot of B that links to the old blobs.
- [x] A file with a new hash still downloads.
- [x] `swift test` passes. #bug