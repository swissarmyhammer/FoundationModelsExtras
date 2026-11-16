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
- actor: claude-code
  id: 01m7j79dsk2qg9zje4m4pvy1fe
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; engine 7 findings (7 confirmed, 2 refuted) and 1 finding from a manual check, total 8 — DownloadRetryPolicy.swift:12, FileTransfer.swift:231, ResumableFileDownload.swift:65, ResumableFileDownload.swift:90, ResumableFileDownload.swift:146, HubStub.swift:256, StallClock.swift:19, StalledDownloadTests.swift:89
    - manual checks: (1) token on a cross-host redirect: defect, recorded at ResumableFileDownload.swift:90. (2) FileLock and the move of `.incomplete` to the blob: no defect. The download holds the same `flock` lock path that the upstream download and `HubCache.storeFile` take, it checks the blob again after it gets the lock, and the move is a rename in the same folder. (3) cancel of the caller task: no defect. The cancel handler cancels the data task, `outcome` closes the handle and keeps the bytes, and `attempt` throws `CancellationError`, which the retry loop does not catch.
    - next: implement the 8 findings, then review again.
  timestamp: 2026-11-16T13:03:36.755340+00:00
- actor: claude-code
  id: 01m7j7a0s8ncmxtrphw8fyenq1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files (DownloadRetryPolicy, FileTransfer, ResumableFileDownload, SnapshotByteProgress new; BlobReusingDownloader, HubSource; tests StallClock, StalledDownloadTests new; HubStub, HubSourceDownloaderTests)
    - test: green — swift test two times, 2614 passed each time, 0 failed, 0 skipped, 0 hangs
    - commit: beefee8
    - review: findings — DownloadRetryPolicy.swift:12, FileTransfer.swift:231, ResumableFileDownload.swift:65, ResumableFileDownload.swift:90, ResumableFileDownload.swift:146, HubStub.swift:256, StallClock.swift:19, StalledDownloadTests.swift:89
    - Do not push beefee8 before the token finding (ResumableFileDownload.swift:90) is fixed.
  timestamp: 2026-11-16T13:03:56.200921+00:00
- actor: claude-code
  id: 01m7j7eprwgzm5r5ramvqebcjk
  text: 'Picked up the 8 review findings. Plan: (1) FileTransfer gets the redirect delegate method; it removes `Authorization` when the new host is not the host of the original request (case-insensitive compare). HubStub gets a redirect option and records the headers of each request, thus a test sees the headers at the second host. (2) The write-failure test needs a seam: a write to a real FileHandle does not fail in a test, and ARC closes a FileHandle on release, thus the test injects a blob writer whose write fails and which records `close()`. (3) The progress clamp goes in `SnapshotByteProgress.record` (the count of a file keeps its maximum), because a 416 restart and a server that ignores the range both start the blob again from zero. (4) `ResumableFileDownload.size(of:)` goes; `HubSource` gets a throwing wrapper that gives 0 only for a missing file. (5) New tests for a cancel of the caller task.'
  timestamp: 2026-11-16T13:06:29.788118+00:00
- actor: claude-code
  id: 01m7j8314d7qqp4mz784qvbns7
  text: |-
    Fixed the 8 findings.
    - Token on redirect: `FileTransfer` now implements `willPerformHTTPRedirection`; it removes `Authorization` when the new host is not the host of `task.originalRequest` (case-insensitive). The `Range` header stays. `HubStub` got a `redirect:` option on `.repository`: the redirected request holds each header of the first request, as the URL session makes it for a real HTTP redirect. The cross-host test failed first (the token reached the CDN host).
    - Write failure: a `BlobWriter` seam (`FileHandle` conforms) lets a test give a writer whose write fails. `State.replaceSink(with:)` closes the writer when the sink leaves `.file`; this covers the write failure and also a second `didReceive response`. Without a seam no test can see the defect: ARC closes a released `FileHandle`.
    - 416 progress: the clamp is in `SnapshotByteProgress.record` (the count of a file keeps its maximum). It also covers a server that ignores the range. The test drives `ResumableFileDownload` into a `SnapshotByteProgress` directly, because the stall wait of `StallClock` must see the raw blob bytes; with the snapshot progress the wait was racy. `HubStub` no longer counts a refused-range request as a stall entry.
    - Cancel tests: they passed at once (no defect, as the review said). A mutation that removed `Task.checkCancellation()` did not make them fail, because the cancelled watch also throws `CancellationError`.
    - The 5 acceptance checkboxes stay unchecked; this pass did not change them.
  timestamp: 2026-11-16T13:17:35.757713+00:00
- actor: claude-code
  id: 01m7j834az1czj5bw1rperwj02
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0, one run: 2622 tests pass (2614 before, plus 8 new), 0 failures; 0 warnings in Sources/ or Tests/ (the only warning is the build-system "missing creator" line for the mlx bundle). swiftlint no_magic_numbers clean on the changed files.
    - files: Sources/FoundationModelsExtras/ModelPool/{FileTransfer,ResumableFileDownload,SnapshotByteProgress,DownloadRetryPolicy,HubSource,BlobReusingDownloader}.swift; Tests/FoundationModelsExtrasTests/ModelPool/{HubStub,StallClock,StalledDownloadTests}.swift; new Tests/FoundationModelsExtrasTests/ModelPool/{ResumableFileDownloadTests,FileTransferTests}.swift.
    - findings: 8 of 8 checked.
    - next: /review
  timestamp: 2026-11-16T13:17:39.039195+00:00
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

## Review Findings (2026-11-16 06:57)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsExtras/ModelPool/DownloadRetryPolicy.swift:12` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsExtras/ModelPool/FileTransfer.swift:231` `completeness/invariant-propagation` — When a write fails, `take` replaces the `.file(handle, ...)` sink with `.failed(error)` without closing the handle. `outcome(of:error:)` closes the handle only for the `.file` case, so the `.failed` case never closes the blob. The type's doc comment says the blob is closed when the task ends, and that does not hold on the write-failure path. The handle is left open until ARC releases it, and a retry then opens the same blob again. Close the handle when the sink leaves `.file` for `.failed`. For example, in `take` call `try? handle.close()` before `state.sink = .failed(error)`, or keep the handle in a separate field that `outcome` always closes. Add a test that makes a write fail and checks that the handle is closed before the retry opens the blob.
- [x] `Sources/FoundationModelsExtras/ModelPool/ResumableFileDownload.swift:65` `completeness/invariant-propagation` — The 416 handler deletes the `.incomplete` blob, so the next attempt starts at zero. That breaks the no-backward-progress rule that the same type states for retries. `SnapshotByteProgress.record` then lowers `completedBytes` for this file, and the download reports fewer bytes than it reported before. The rule holds for stalls and is not applied on this path, and no test covers a 416 restart with the progress handler. Either document the 416 restart as a second exception to the no-decrease rule, or keep the reported count from going down (for example by clamping the report to the previous maximum). Add a test that drives a 416 restart through the progress handler and asserts the completed bytes never decrease, or that the documented exception is what happens.
- [x] `Sources/FoundationModelsExtras/ModelPool/ResumableFileDownload.swift:90` `security/credential-leak-on-redirect` — The request of each file carries the Hugging Face token in the `Authorization` header. The Hub answers a file request with a redirect to a CDN on a different host. `FileTransfer` does not implement `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`, thus the code does not control the headers of the redirected request, and the token can go to the CDN host. `huggingface_hub` removes the token on a cross-host redirect, and the upstream `SameHostRedirectDelegate` also stops each cross-host redirect for the requests that carry the token. A presigned CDN URL can also refuse a request that holds a second credential. Implement the redirect delegate method in `FileTransfer`: on a redirect to a host that is not the host of the original request, remove the `Authorization` header from the new request and keep the `Range` header. Add a test with a stub that redirects the file request to a different host, and check that the request to that host has no `Authorization` header and has the same `Range` header.
- [x] `Sources/FoundationModelsExtras/ModelPool/ResumableFileDownload.swift:146` `reuse/reuse` — The new static `size(of:)` reimplements the byte count of a blob file, which the existing `HubSource.blobBytes(of:)` already does. Two file-size helpers now exist in the same module, and they can drift apart. The new one also swallows errors and returns 0, while the existing one throws and returns an optional. Callers in this change use both (`downloadFile` calls `HubSource.blobBytes`, while `byteProgress` and `attempt` call `ResumableFileDownload.size(of:)`). Call `HubSource.blobBytes(of:)` from `ResumableFileDownload` and `BlobReusingDownloader`, and remove `ResumableFileDownload.size(of:)`. If the non-throwing 0-on-missing behaviour is needed, add a small non-throwing wrapper to the existing function rather than a second implementation.
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/HubStub.swift:256` `reuse/reuse` — The loop in `recordWritten` repeats the loop in `recordStall`: each one takes the reached waiters under the lock, then resumes each continuation. Two copies of the same wake-up sequence in one file can drift apart, and a fix to one would be missed in the other. Move the take-and-resume pair into one private method on `HubStub`, such as `resumeReachedWaiters(_ update: (inout StallState) -> Void)`, and call it from both `recordStall(end:)` and `recordWritten(_:)`.
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/StallClock.swift:19` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/StalledDownloadTests.swift:89` `test-integrity/no-test-cheating` — The test discards the result of the download with `try?`. The download is expected to throw `ModelDownloadError.stalled` after the retry limit, but the test never checks the error. If the download fails for another reason after two backoffs, the test still passes, so the test does not prove the error path it names. Assert the thrown error as well, for example with `await #expect(throws: ModelDownloadError.stalled(repository: Self.repository, file: Self.weights.path, attempts: Self.retryLimit + 1)) { try await download(stub: stub, fixture: fixture, clock: clock) }`, and then assert `clock.backoffs` in the same test.