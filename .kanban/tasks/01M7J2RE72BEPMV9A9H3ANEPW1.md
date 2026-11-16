---
assignees:
- claude-code
position_column: todo
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
- [ ] A regression test with a temporary hub cache: the blobs of revision A are present, revision B lists the same hashes, and the download of B makes no file request (a stub transport counts the requests) and gives a snapshot of B that links to the old blobs.
- [ ] A file with a new hash still downloads.
- [ ] `swift test` passes. #bug