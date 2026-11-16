---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7j60020dsv25gr04879ed2q
  text: |-
    Research. The upstream does NOT keep the bytes of a cancelled download in `<etag>.incomplete`. In swift-huggingface 0.13.0, `hfAsyncDownload` uses a `URLSessionDownloadTask`, which writes to a temporary file of URLSession. On a cancel, `DownloadTaskBox.cancel()` calls `task.cancel()` (not `cancel(byProducingResumeData:)`), thus URLSession deletes that file. `downloadFile` writes `.incomplete` only after a complete 206 answer (it appends the temporary file and then moves it to the blob). Thus a watchdog that cancels the upstream download and calls it again starts each file from byte 0, and sends no Range header.

    The other way: `BlobReusingDownloader` already has the tree listing (etag and size of each file) of the commit. Before the upstream download, it now downloads each file of the patterns whose blob is not in the cache, with its own transfer: a data task that writes each chunk to `<etag>.incomplete` as it arrives, under the same `FileLock` as the upstream. A watchdog stops the request when no bytes arrive for the stall interval; the next attempt sends `Range: bytes=<size of .incomplete>-`. Exponential backoff between attempts, a retry limit, then a stall error. When the file is complete, the `.incomplete` blob moves to the blob and the snapshot gets the link. The upstream download then finds each file in the cache and sends no file request (as the blob reuse already does). All three loaders (MLX, Core ML, GGUF) use `HubSource.downloader()`, thus all get the retry. When the Hub gives no commit or no listing (for example with no network), the upstream download runs as before.

    Note: URLSession also gives `URLError.timedOut` when no data arrives for `timeoutIntervalForRequest`; the transfer treats that error as a stall too.
  timestamp: 2026-11-16T12:40:59.200611+00:00
- actor: claude-code
  id: 01m7j6trhr7p8yrgrtc38d7bnx
  text: |-
    Correction to the research comment: the transfer does NOT treat `URLError.timedOut` as a stall. The watch starts at the start of each attempt, and its default interval (30 s) is shorter than the request timeout of the session (60 s). Thus the watch always stops a stalled attempt first, and a mapping of `timedOut` would be a branch that no test can reach. A `timedOut` error goes to the caller as before.

    Discovery: with no `Content-Type` in an answer, URLSession keeps the first bytes of the answer to find the type (MIME sniffing). Thus a stub answer that sends 40 bytes and then stalls gave no bytes to the delegate, and the test hung. The stub now sends `Content-Type: application/octet-stream`, as the Hub does.

    Test design: no test waits on the wall clock. `StallClock` (Tests/.../ModelPool/StallClock.swift) gives the `sleep` of the `DownloadRetryPolicy`. A sleep of the stall interval ends only when the stub recorded the next stall AND the progress of the download reached the end of the bytes of the stalled request; each other sleep is a backoff that ends at once and is recorded. The count of the backoffs tells which stall the next watch waits for.
  timestamp: 2026-11-16T12:55:36.248287+00:00
- actor: claude-code
  id: 01m7j6vhc5jrfdknawbj248ndx
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0; 2614 Swift Testing tests in 245 suites pass, 0 failures; 0 build warnings in Sources/ or Tests/. New suite StalledDownloadTests: 10 of 10 pass in about 0.02 s. No test waits on the wall clock.
    - files: new Sources/FoundationModelsExtras/ModelPool/{DownloadRetryPolicy,FileTransfer,ResumableFileDownload,SnapshotByteProgress}.swift; changed BlobReusingDownloader.swift, HubSource.swift; new Tests/.../ModelPool/{StallClock,StalledDownloadTests}.swift; changed HubStub.swift, HubSourceDownloaderTests.swift.
    - note: the tests for the 416 restart, the HTTP error and the concurrent limit were written after their code. The tests for the stall retry, the stall error and the progress were written first, and they failed first.
    - next: /review
  timestamp: 2026-11-16T12:56:01.669808+00:00
depends_on:
- 01M7J2RE72BEPMV9A9H3ANEPW1
position_column: doing
position_ordinal: '8180'
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