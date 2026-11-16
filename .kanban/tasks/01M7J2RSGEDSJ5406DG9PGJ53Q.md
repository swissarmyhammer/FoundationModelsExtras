---
assignees:
- claude-code
depends_on:
- 01M7J2RE72BEPMV9A9H3ANEPW1
position_column: todo
position_ordinal: '8280'
title: 'Download: retry a stalled download with a Range request, a backoff and a retry limit'
---
## Defect
When no bytes arrive for a time, a model download waits for ever. It must stop the request and retry from the bytes already written.

## Where
The downloads go through `#hubDownloader(hubClient())` in `MLXModelLoader.swift:154` and `CoreMLModelLoader.swift:116`, wrapped in `ProgressReportingDownloader`, and through `GGUFSource.swift:98`. The upstream `swift-huggingface` 0.13.0 `downloadFile` (`HubClient+Files.swift` ~line 697) already resumes from `<etag>.incomplete` with `Range: bytes=<offset>-`, but it has no stall detection.

## Fix
Fix it in Extras, not in the upstream package. For example, a stall watchdog around the upstream download: when the progress gives no new bytes for a stall interval, cancel the download task and call the download again, which resumes from the `.incomplete` blob with a Range request. Use an exponential backoff between the attempts and a retry limit; after the limit, throw an error that names the stall. Check that the Range resume really happens (the bytes of the `.incomplete` blob are kept on cancel); if the upstream deletes them on cancel, find another way and write it in a comment on this task.

The stall interval, the backoff and the retry limit are parameters with defaults, so a test can use short times. The test must not use the wall clock to wait (inject a clock or a sleep function).

The progress (`bytesDownloaded` / `ModelLoadProgress.downloading(completedBytes:)`) must never go backward over a retry. `DownloadByteCounter` already keeps the maximum; check that it holds across attempts.

## Acceptance
- [ ] A test with a stub transport that sends some bytes, then stalls: the download retries with `Range: bytes=<written>-`, ends complete, and the file is correct.
- [ ] A test where each attempt stalls: the download stops after the retry limit and throws the stall error.
- [ ] A test that the progress reports never go backward over a retry.
- [ ] All three download paths (MLX, Core ML, GGUF) get the retry.
- [ ] `swift test` passes. #bug