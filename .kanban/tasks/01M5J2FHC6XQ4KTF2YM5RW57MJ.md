---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5j2q770cb5cqcj3zmzrg77y
  text: 'Research: no JSONL code exists in Extras yet. Prior art: Router `Recording/TranscriptLineDecoding.swift` (drop undecodable final line w/ warning, throw on earlier) and `Recording/JSONLines.swift` (iso8601 dates, sortedKeys, withoutEscapingSlashes); Kanban `Events/EventLog.swift` (FileHandle append + separate synchronize). Extras telemetry is content-safe: pool tests assert telemetry "holds no path", so the torn-tail warning logs the byte offset only, through `ExtrasTelemetry.makeLogger()`. Tests use Swift Testing, `FixtureSupport.TemporaryDirectory.make()`, and `TelemetryTestSupport.TelemetryCapture.run(forbidding:)` to assert log records. Root-level source files use 2-space indentation; no swift-format config in the repo. Plan: `Sources/FoundationModelsExtras/JSONLFile.swift` (struct JSONLFile, JSONLFileError, JSONLKeyedRecord protocol for the last-wins fold), internal write/fsync seam so a test can prove one write(2) per line and fsync before return; `Tests/FoundationModelsExtrasTests/JSONLFileTests.swift`.'
  timestamp: 2026-10-22T15:12:22.240371+00:00
- actor: claude-code
  id: 01m5j34f8aeefzzfcq7vm5krh7
  text: |-
    Implementation landed (TDD: the new suite failed first on the missing symbols, then went green).

    API: `JSONLFile(url:)` with `append(_: some Encodable) throws(JSONLFileError)`, `records(as:)`, `latestRecords(as:)` and `static fold(_:)`; protocol `JSONLKeyedRecord` (`key`, `isTombstone`); enum `JSONLFileError` (encodingFailed, openFailed, writeFailed, shortWrite, syncFailed, closeFailed, readFailed, corruptLine(number:byteOffset:)). Each append runs its own open(O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC, 0644), one write(2), fsync, then close. EINTR is retried only when the call did nothing. A short write throws and never writes the rest, because the rest could land after another appender's line. The line format is fixed: sortedKeys, withoutEscapingSlashes, ISO 8601 dates (the same as Router's JSONLines). A missing file reads as no records. The folder must already exist: an append to a missing folder throws openFailed(ENOENT).

    Torn-tail definition: the bytes after the last `\n` are always dropped, whether they decode or not, with a warning `ExtrasTelemetry.JSONLLogMessage.tornTailDropped` and metadata `file.byte_offset`. No path goes in the record, so telemetry stays content-safe. A line that ends with its `\n` and does not decode throws corruptLine, also when it is the last line.

    Testability seam: `JSONLFile.Calls` (internal) holds the write/fsync closures. A test records them to prove that each append is exactly [write(whole line + \n), fsync], and another test injects a half write to prove that a short write throws.

    Concurrency test: two task-group appenders, each its own JSONLFile, write 200 records with 16 KiB padding (> PIPE_BUF). Every line decodes, and each writer's sequence stays in order. This is in-process: each append opens its own open file description, which is the same kernel O_APPEND path that a second process uses. I spawned no real second process. If a true two-process proof is wanted, an `extras-demo jsonl-append` subcommand could drive it.

    Not done (not on the card): no README section and no parent-directory fsync after the file is created. Also, if one appender's write is torn and another process appends after it, the torn bytes become a corrupt middle line and the read throws. POSIX cannot avoid this without a rewrite.
  timestamp: 2026-10-22T15:19:36.458925+00:00
- actor: claude-code
  id: 01m5j34j8x29r5bkak72d9gdhm
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/JSONLFile.swift (new), Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift (LogMetadataKey.byteOffset, JSONLLogMessage), Tests/FoundationModelsExtrasTests/JSONLFileTests.swift (new, 14 tests). `swift test --filter JSONLFileTests`: 14/14 pass. Full `swift test`: all suites pass (core 1530 tests / 156 suites). The only warning is SwiftPM's "missing creator for mutated node" on the mlx-swift_Cmlx.bundle dependency, which comes from no file of this change.
    - next: /review
  timestamp: 2026-10-22T15:19:39.549564+00:00
- actor: claude-code
  id: 01m5j5ktjnv6pry5h9hbjbvj7f
  text: |-
    ### Spec amendment — user decision 2026-10-22 (torn tail heal + skip)
    Gap (raised by the Router session): after a crash leaves a torn last line, the next O_APPEND record lands right after it, so the torn bytes become a corrupt middle line and every later read would throw.
    Decision (user): **Heal + skip.**
    - [ ] Writer: before its first write, check the file's last byte; if the file is non-empty and that byte is not `\n`, append a `\n` first (still append-only, no truncate/seek of the write fd; reading the last byte through a separate read fd is fine).
    - [ ] Reader: a complete line that does not decode is **skipped with a warning** (no path in the log, offset/line number only), not thrown. This replaces "a corrupt middle line throws". The torn final line is still dropped with a warning.
    - [ ] Tests: the crash → torn tail → append → read sequence yields every whole record; a corrupt middle line is skipped and the records around it are kept.
  timestamp: 2026-10-22T16:02:56.725839+00:00
- actor: claude-code
  id: 01m5j5tkd67kpbwx5pdrg3kb8c
  text: |-
    Spec amendment (heal + skip) implemented, failing tests first. RED: 4 new tests failed for the expected reasons: there was no heal, and corrupt lines still threw.

    - Writer: before each append's write, `endsWithTornLine` runs fstat and then pread(2) on the last byte. If the file is non-empty and that byte isn't `\n`, the append sends `"\n" + line` in the same single write(2), so it is still one write per append. The append descriptor is now opened O_RDWR|O_APPEND|O_CREAT|O_CLOEXEC so it can pread. pread moves no offset, so there is no seek and no truncate. The amendment allowed a separate read descriptor, but I chose the same descriptor to save an open per append. There is a new error case, `tailCheckFailed(errno:)`.
    - Reader: a whole line that doesn't decode is now skipped with a warning (`JSONLLogMessage.corruptLineSkipped`, metadata `file.line_number` + `file.byte_offset`, no path). The records around it are kept. `JSONLFileError.corruptLine` is removed (no backward compatibility). The torn final line is still dropped with its own warning.
    - Known edge, documented in the type doc: if two appenders heal the same torn tail at once, the second `\n` makes an empty line, which a read skips with a warning.
    - Tests: the two corrupt-line throw tests became skip+warning tests (middle line, and final line with its newline). New tests: an append after a torn tail writes exactly `torn bytes + \n + line`, and a crash → torn tail → append → read sequence gives every whole record.
  timestamp: 2026-10-22T16:06:38.758799+00:00
- actor: claude-code
  id: 01m5j5tnxyfgvf3eh5pbzp0667
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/JSONLFile.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift (LogMetadataKey.lineNumber, JSONLLogMessage.corruptLineSkipped), Tests/FoundationModelsExtrasTests/JSONLFileTests.swift. `swift test --filter JSONLFileTests`: 16/16 pass. Full `swift test`: all suites pass (core 1532 tests / 156 suites). The only warning is SwiftPM's "missing creator for mutated node" on the mlx-swift_Cmlx.bundle dependency, which does not come from any file in this change.
    - next: /review
  timestamp: 2026-10-22T16:06:41.342024+00:00
- actor: claude-code
  id: 01m5j5ycgxpmxj7gyn3szvzgf2
  text: |-
    ### test — green
    - evidence: `swift test` — 1532 tests in 156 suites passed (main target), 0 failed, 0 skipped; other targets 131/40/44/26/410 tests passed. Exit 0. The only warning is the SwiftPM build-system line "missing creator for mutated node ... mlx-swift_Cmlx.bundle", from a dependency bundle, not our code.
    - formatting: the repo holds no formatter config (.swift-format, .swiftformat, .swiftlint.yml absent; no Airbnb plugin), so tool defaults applied. `swift format lint -s` reported LineLength x8 and one TrailingComma in JSONLFile.swift and JSONLFileTests.swift; `swift format -i` on those two files fixed them, lint now clean. ExtrasTelemetry.swift and older files were left alone (4-space legacy style, thousands of default-rule hits not from this task).
    - next: review
  timestamp: 2026-10-22T16:08:42.781798+00:00
- actor: claude-code
  id: 01m5j5z3mvb4h86ca7rpstt0ga
  text: |-
    ### commit — changed
    - evidence: e846c1b feat(jsonl): JSONLFile, the append-only JSONL writer and reader (local, not pushed)
    - next: review
  timestamp: 2026-10-22T16:09:06.459186+00:00
- actor: claude-code
  id: 01m5j6avvhzccbbm1n43r0zdzv
  text: |-
    ### review — findings
    - evidence: `review sha e846c1b~1..e846c1b` — 2 findings (2 confirmed, 2 refuted): Sources/FoundationModelsExtras/JSONLFile.swift:203 (reuse/reuse, iso8601 JSONDecoder duplicates MarketplaceState.swift), Sources/FoundationModelsExtras/JSONLFile.swift:359 (reuse/reuse, retryingInterrupts duplicates ProcessRunner.swift). Style check: JSONLFile.swift and JSONLFileTests.swift use 2-space indentation like their root-level siblings (ProcessRunner.swift, ProcessRunnerTests.swift, PathConfinementTests.swift; 61 of 78 root files use 2 spaces). The ExtrasTelemetry.swift additions keep that file's 4-space style. No style mismatch.
    - next: /implement the two unchecked items under `## Review Findings (2026-10-22 11:09)`, then re-review
  timestamp: 2026-10-22T16:15:31.697165+00:00
- actor: claude-code
  id: 01m5j6bdefdbvjq0ypz7xf7bcy
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files (JSONLFile.swift, ExtrasTelemetry.swift, JSONLFileTests.swift), incl. heal+skip amendment
    - test: green — swift test, 1532 passed (main target), 0 failed, 0 skipped
    - commit: e846c1b
    - review: findings — Sources/FoundationModelsExtras/JSONLFile.swift:203, Sources/FoundationModelsExtras/JSONLFile.swift:359
  timestamp: 2026-10-22T16:15:49.711167+00:00
- actor: claude-code
  id: 01m5j6kkh0q9h4em5nkvetss95
  text: |-
    Review findings fixed, failing tests first (RED: new suites failed to compile on the missing `SystemCall` / `ISO8601JSON`; GREEN: 5/5).

    - Finding 1 (iso8601 decoder): new `Sources/FoundationModelsExtras/ISO8601JSON.swift`, a `package enum ISO8601JSON` with `makeEncoder(outputFormatting:)` and `makeDecoder()`. `package` access because MarketplaceState lives in the separate `Marketplace` target; this is the first `package` declaration in the repo (SwiftPM passes -package-name, tools 6.2). The cause was removed across both files: the iso8601 *encoder* setup was duplicated too (JSONLFile.line(of:) and MarketplaceState.save), so both now call `makeEncoder`, and JSONLFile.makeDecoder is deleted. MarketplaceState.swift gained `import FoundationModelsExtras`.
    - Finding 2 (retryingInterrupts): new `Sources/FoundationModelsExtras/SystemCall.swift`, `enum SystemCall` (internal) with `failure = -1` and `retryingInterrupts(_:) -> (value, errorNumber)`. JSONLFile drops its private copy and its private `systemCallFailure` constant and uses `SystemCall` for every call. ProcessRunner: its throwing wrapper is renamed `checkedWait(_:)` and now delegates to `SystemCall.retryingInterrupts` (no more literal `-1`), and the hand-rolled `count < 0 && errno == EINTR` loop in `readToEnd` was the same cause, so it now reads through `SystemCall.retryingInterrupts` too.
    - Card description: What/Subtasks now state the amended heal + skip rule (no "corrupt middle line throws"); both findings flipped to [x].
    - No ARCHITECTURE.md change needed: it documents only the no-backward-compatibility rule, no module map.
  timestamp: 2026-10-22T16:20:18.080119+00:00
- actor: claude-code
  id: 01m5j6kpsvbbbt0rmgd33sn9wa
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/SystemCall.swift (new), Sources/FoundationModelsExtras/ISO8601JSON.swift (new), Sources/FoundationModelsExtras/JSONLFile.swift, Sources/FoundationModelsExtras/ProcessRunner.swift, Sources/Marketplace/MarketplaceState.swift, Tests/FoundationModelsExtrasTests/SystemCallTests.swift (new), Tests/FoundationModelsExtrasTests/ISO8601JSONTests.swift (new). `swift test`: exit 0, main target 1537 tests / 158 suites passed, other targets 131/40/44/26/410 passed, 0 failed. Only warning is SwiftPM's "missing creator for mutated node" on the mlx-swift_Cmlx.bundle dependency. `swift format lint -s` clean on the new/changed 2-space files. Not committed.
    - next: /review
  timestamp: 2026-10-22T16:20:21.435235+00:00
- actor: claude-code
  id: 01m5j6psxqn4ej818cffd76wm8
  text: |-
    ### test — green
    - evidence: `swift test` — 1537 tests in 158 suites passed, 0 failed, 0 skipped, no compiler warnings; `swift format lint -s` on the 7 changed/new files clean. One finding fixed: ProcessRunner.swift `[LineLength] line is too long` (the delegating `run` call re-wrapped).
    - next: review
  timestamp: 2026-10-22T16:22:02.935007+00:00
- actor: claude-code
  id: 01m5j6qcgmbedpxfyszbknyn6z
  text: |-
    ### commit — changed
    - evidence: refactor(extras): share ISO8601JSON coder and SystemCall.retryingInterrupts; JSONLFile review fixes (local, not pushed; sha is the HEAD commit that contains this comment)
    - next: review
  timestamp: 2026-10-22T16:22:21.973+00:00
position_column: doing
position_ordinal: '80'
title: JSONLFile — the one append-only JSONL writer and reader (append mode, one full line per write, fsync per line)
---
Copied from FoundationModelsRouter card 01M5HS4C6FBNTAX30161HP0BS5 (../FoundationModelsRouter). Requested by the FoundationModelsKanban session, which is blocked on it (EventLog moves onto it).

## What
Add a `JSONLFile` type to FoundationModelsExtras. It is the only way any of our packages writes or reads a `.jsonl` file. User decisions (2026-10-22, read amended by the "Spec amendment" comment: heal + skip):
- **Append-only:** open with `O_APPEND | O_CREAT`. Never truncate, rewrite or replace the file, and never seek.
- **One full line per write:** each record is encoded, gets its `\n`, and goes out in a single `write(2)`. No buffering in our code.
- **Heal a torn tail:** before its write, an append checks the file's last byte (`pread(2)`, no seek). If the file is non-empty and that byte is not `\n`, the append puts a `\n` in front of its line, in the same single `write(2)`.
- **Flush:** `fsync` after every line, before the append returns.
- **Read:** decode line by line. A torn final line, the expected crash artifact, is dropped with a warning. A whole line that does not decode (anywhere in the file, most often a healed torn line) is **skipped with a warning** (line number and byte offset only, no path), and the records around it are kept. Nothing throws on a bad line.
- **Last line wins:** a helper folds the records by key so the newest line for a key wins, and a tombstone record removes the key. Removal is always an appended tombstone line, never a rewrite.
- Keep concurrent appenders from two processes (Router and ACPAgent on sessions.jsonl) whole: one `O_APPEND` write per line.

No backward compatibility (ARCHITECTURE.md).

## Subtasks
- [x] `JSONLFile` with `append(_:)` (Encodable), `records(as:)` and the last-wins fold with tombstones
- [x] Failing tests first: append-only on disk (file only grows, earlier bytes unchanged); one line per append; torn tail dropped; an append after a torn tail heals it; a corrupt whole line is skipped with a warning and the records around it are kept; crash → torn tail → append → read yields every whole record; tombstone removes a key; two concurrent appenders produce whole lines
- [x] Document the rule in the type doc
- [x] `swift test` passes, zero warnings

#cross-repo #recording

## Review Findings (2026-10-22 11:09)

> Scope: `review sha e846c1b~1..e846c1b` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

- [x] `Sources/FoundationModelsExtras/JSONLFile.swift:203` `reuse/reuse` — The `makeDecoder()` function creates a JSONDecoder with iso8601 date strategy, which is the same pattern already implemented in MarketplaceState.swift. This common decoder configuration should be extracted to a shared utility rather than duplicated. Extract the iso8601 JSONDecoder creation to a shared utility function in a common location (e.g., a JSON utilities module) and call it from both MarketplaceState and JSONLFile.
- [x] `Sources/FoundationModelsExtras/JSONLFile.swift:359` `reuse/reuse` — The `retryingInterrupts` function reimplements the same utility that already exists in ProcessRunner.swift. Both retry a system call while it fails with EINTR. Instead of duplicating, JSONLFile should call the existing implementation or both should share a single extracted version. Extract `retryingInterrupts` to a shared utility function (perhaps in a new module or in an existing utilities file) and call it from both ProcessRunner and JSONLFile, or move it to a protocol extension on SignedInteger if appropriate.
