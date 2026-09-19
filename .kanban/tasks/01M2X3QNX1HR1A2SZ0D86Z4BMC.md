---
comments:
- actor: claude-code
  id: 01m2x5b4b26ebvqbxbfa5ejcb1
  text: |-
    Picked up. Research notes:

    - The source runner is `../FoundationModelsSkills/Sources/FoundationModelsSkills/Resources/ScriptProcessRunner.swift`. It spawns with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`, sends stdout and stderr to one pipe, reads the pipe to EOF with `readDataToEndOfFile` (the full output stays in memory), races `waitpid` against a sleep task, and sends `SIGKILL` to the group when the sleep wins. It keeps the last 32 lines, formatted `"{n}: {text}"`. It does not touch `ProcessRegistry`.
    - `Sources/FoundationModelsExtras/ProcessRegistry.swift` holds `ProcessRegistry` (`register`, `deregister`, `registeredPids`), the top-level `sweep(_:)`, and `ProcessRegistry.global`. `Tests/FoundationModelsExtrasTests/ProcessRegistryTests.swift` spawns `/bin/sleep` with `posix_spawn` and never uses `.global`, because swift-testing runs suites concurrently in one process.
    - No `ARCHITECTURE.md`, no `.swift-format`, no `.swiftformat`. The package uses 2-space indentation. `CHANGELOG.md` records each public API change under `## Unreleased`.
    - Plan: `ProcessRunner` (public enum) with `run(executable:arguments:workingDirectory:timeout:outputCap:registry:)`. The `registry` parameter defaults to `ProcessRegistry.global`, so a test can give a private registry. The result holds a `Termination` enum (`exited(code)`, `signaled(signal)`, `timedOut`), `lineCount`, `output` (the kept tail, plain lines), `isTruncated`, and `duration`. A spawn failure throws `ProcessRunnerError.spawnFailed(status:)`. The read runs in chunks into an internal `OutputTail` accumulator that never keeps more than the byte limit.
  timestamp: 2026-09-19T15:42:45.090555+00:00
- actor: claude-code
  id: 01m2x5w958b8nqcv0xgdgzy2dq
  text: |-
    Implementation landed, with `/tdd`.

    **RED.** `Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift` was written first. `swift build --build-tests` failed with `cannot find 'ProcessRunner' in scope`.

    **GREEN.** Two new source files:
    - `Sources/FoundationModelsExtras/ProcessRunner.swift`: `ProcessRunner.run(executable:arguments:workingDirectory:timeout:outputCap:registry:)`, `OutputCap`, `Termination` (`.exited(code:)`, `.signaled(_:)`, `.timedOut`), `Outcome`, and `Failure` (`.spawnFailed(status:)`, `.waitFailed(errno:)`). `registry` defaults to `ProcessRegistry.global`; `register` runs directly after the spawn and `deregister` runs in a `defer`, so it covers the normal path, the timeout path, and the error path. The reap and the pipe read run off the cooperative pool through one `blocking` helper.
    - `Sources/FoundationModelsExtras/ProcessOutputTail.swift`: the bounded accumulator. It splits chunks at `\n`, counts every line, keeps at most `lineCount` lines and at most `byteLimit` bytes (the line in progress included), and cuts the oldest bytes as soon as a limit is passed.

    One test failed on the first green run: the working-directory test compared `pwd` with a path that had not crossed the `/var` firmlink. `URL.canonicalDirectory` gives the URL unchanged when the path does not exist yet, so the test now creates the directory first and canonicalizes after. Noted for the next agent: canonicalize after `createDirectory`, not before.

    **REFACTOR.** Merged the two off-pool helpers into one `blocking` helper; narrowed two accumulator properties to `private`; named every numeric literal in the tests; wrapped lines past 100 columns. `CHANGELOG.md` records the public API under `## Unreleased`.

    **Verification.** `swift build --build-tests`: 0 warnings, 0 errors. `swift test`: 316 tests in 27 suites, 0 failures. The new suite ran 3 more times with the same result (14 tests, about 0.5 s each run). `swift format lint` reports nothing on the three new files. No `skill`, `marketplace` or `dotfolder` word in the new sources.

    **Design notes.** A cancel of the calling task acts as a timeout: the sleep task throws at once, the group gets `SIGKILL`, and the outcome reads `.timedOut`. `Failure.waitFailed` has no unit test: it needs a host that ignores `SIGCHLD`, which is a process-wide setting that would reach the other suites.

    **Follow-up card.** ^d1w8t5f: document `ProcessRunner` in the README and note the plan.md scope extension, in the shape of the `IgnoreProcessor` and `Doctorable` cards.
  timestamp: 2026-09-19T15:52:07.080525+00:00
- actor: claude-code
  id: 01m2x5wb7qwqxjs123jcqv991f
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsExtras/ProcessRunner.swift (new), Sources/FoundationModelsExtras/ProcessOutputTail.swift (new), Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift (new), CHANGELOG.md; `swift build --build-tests` 0 warnings; `swift test` 316 tests, 0 failures
    - next: /review
  timestamp: 2026-09-19T15:52:09.207427+00:00
- actor: claude-code
  id: 01m2x610sftqvwr2st9hf3ezdd
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (clean rebuild, zero warnings); `swift test` — 316 tests in 27 suites, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-19T15:54:42.351903+00:00
position_column: doing
position_ordinal: '80'
title: 'Move the process runner into Extras: group, timeout, output cap, and the registry'
---
## What

`FoundationModelsExtras` holds `ProcessRegistry`, "the family's no-leak backstop for spawned process groups", with an `atexit` sweep. `FoundationModelsSkills` has **0** uses of it, and it holds a full process runner of its own (`Sources/FoundationModelsSkills/Resources/ScriptProcessRunner.swift`, 252 lines): it spawns a process group, merges stdout and stderr, holds a timeout, kills the group with `SIGKILL`, and keeps the tail of the output.

That runner is not skill semantics. It belongs beside the registry, thus each consumer of the family gets the same limits and the same backstop.

1. **Move the runner into Extras** as `ProcessRunner`, with no skill vocabulary in it. Its inputs: the executable, the arguments, the working directory, the timeout, and the caps of the output (the count of the lines that it keeps, and the byte limit).
2. **The runner registers the pid** with `ProcessRegistry.global` directly after the spawn, and it deregisters after the group kill and the reap. This is the part that is missing today: a session that ends while a script runs leaves the group.
3. **The result** names what happened: the exit code, or the timeout; the total count of the lines; and the output that was kept, with a mark when it was cut.
4. **The output is bounded in memory.** The read must not hold the full output of a process that writes without end. Cut at the byte limit while the read runs, and keep the tail.
5. `ScriptProcessRunner` in `FoundationModelsSkills` is deleted by the card ^977h3a0 on that board, after this one lands.

## Acceptance Criteria

- [x] `ProcessRunner` gives the behavior of the runner that moved: the process group, the merged output, the timeout, the `SIGKILL` of the group, and the tail of the output.
- [x] The pid is registered before the wait and deregistered after the reap, also on the timeout path and on the error path.
- [x] A process that writes without end does not grow the memory of the caller: the read stops at the byte limit.
- [x] A process that ends on its own gives its exit code; a process that passes the timeout gives the timeout result.
- [x] No type of `ProcessRunner` names a skill, a marketplace or a dotfolder.
- [x] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [x] `Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift` (new): a command that ends gives its exit code and its output.
- [x] Same file: a command that sleeps longer than the timeout gives the timeout result, and the group is gone after the call.
- [x] Same file: a command that writes more than the byte limit gives the tail, with the mark, and the memory does not hold the full output.
- [x] Same file: the registry holds the pid while the process runs, and holds nothing after the call, for the normal path and for the timeout path.
- [x] Same file: a child that makes a child of its own is also killed, because the kill goes to the group.
- [x] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#process-safety #cross-repo