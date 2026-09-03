---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1mk0qkxn640y594vchz8a18
  text: |-
    Research and implementation notes.

    **Why `readabilityHandler` + `DispatchGroup`, and not `withTaskGroup`.** The card
    offered both. `withTaskGroup` makes `run(arguments:)` `async`, which forces every
    one of the 11 tests that call it to become `async` and to `await`. The card says
    each call site must stay unchanged, so the Dispatch route is the one that fits.
    `run(arguments:)` stays synchronous and no test signature moved.

    **Why a `StreamBuffer` class and not a captured `var`.** The package builds in
    Swift 6 language mode (`-swift-version 6`, tools 6.2), so a `var` mutated from a
    read handler is a data race the compiler rejects. `Mutex` is non-copyable and so
    cannot itself be captured by an escaping closure. A `final class ... : Sendable`
    holding a `Mutex` is the way around both, and it is the pattern
    `Sources/FoundationModelsExtras/ProcessRegistry.swift` already uses.

    **Handlers are installed after `try process.run()`.** No data is lost: bytes
    written before the handler exists stay in the pipe buffer, and if the child has
    already exited the source fires at once with an empty read. Installing before the
    launch would leave a `group.enter()` unbalanced whenever `run()` throws.

    **Both claims in the new doc comment are measured, not asserted.** Two scratch
    programs carried the exact harness code against `/bin/sh` writing 2 MB to each
    stream (about 32x the pipe buffer):
    - concurrent drain: 2000000 bytes on each stream, exit 0, 0.36 s.
    - sequential read (stdout to end, then stderr): still blocked after 25 s, killed.
      This is the deadlock the one-pipe harness existed to dodge.

    **Discovery, latent deadlock elsewhere.**
    `Tests/FoundationModelsExtrasTests/IgnoreGitParityTests.swift` has the same
    sequential two-pipe read in `runCheckIgnore(probePaths:repoURL:)` — stdout to end
    of file, then stderr, then `waitUntilExit()`. It does not hang today only because
    `git check-ignore` output stays small. Out of this card's scope (one file), so it
    is filed as its own task.
  timestamp: 2026-09-03T21:32:52.733588+00:00
- actor: claude-code
  id: 01m1mkbmm17vyd7mfhb417g962
  text: |-
    Validator rules were dumped for `.swift` before the edits and read whole. Two of
    them landed on code written for this card, and both are corrected:

    - `swift / initialization`, "A callback closure that branches calls a named
      method." The first draft branched inside the `readabilityHandler` closure. The
      branch moved into `StreamBuffer.readChunk(from:endingWith:)`, and the closure
      is now one forwarding call.
    - `swift / concurrency`, "Model new shared mutable state as an `actor`, not a
      hand-rolled `DispatchQueue`/`NSLock`." An `actor` cannot serve here: its every
      access is `await`, and `readabilityHandler` is a synchronous callback, so an
      actor would force `run(arguments:)` to become `async` and break the card's
      "each call site is unchanged" criterion. `StreamBuffer`'s doc comment now
      states that reason, next to the same reason `ProcessRegistry` gives for being
      lock-based rather than an actor.

    Checked and clean: no numeric literal was added (the 64 KB figure is prose in the
    doc comment only); the two drains are one function called twice, not two arms; no
    `guard` was added inside a test body; `print` was not used; `Process.arguments`
    stays a list, never a shell string; `output`, `stdout` and `stderr` each have a
    reader.

    **Open question for a person, not fixed here.** `test-integrity /
    test-partitioning` item 3 says a test that spawns a real external process belongs
    in an integration target, and Swift's form of that is a nested `IntegrationTests/`
    package run with `swift test --package-path IntegrationTests`. This whole file
    spawns the built `extras-demo` binary, and `IgnoreGitParityTests.swift` spawns
    `git`; both sit in the root unit test target today. That is a pre-existing
    decision of the package, and this card names one file, so nothing was moved. It
    needs a decision before it becomes a task.
  timestamp: 2026-09-03T21:38:50.113256+00:00
- actor: claude-code
  id: 01m1mkbt2298v9zt0hnvsbj0j3
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift. `swift test --filter ExtrasDemoIntegrationTests` 12 tests passed (8 repeat runs, no hang). `swift test` 251 tests in 23 suites passed, 3.5 s. `swift build --build-tests` zero warnings, zero errors. Out-of-band drain proof: 2 MB on each stream drained whole in 0.28-0.36 s; the same load read sequentially still blocked after 25 s.
    - next: /review
  timestamp: 2026-09-03T21:38:55.682112+00:00
- actor: claude-code
  id: 01m1mkkkkvsj50bc10g66sjakz
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (checkpoint 75addea) — 0 findings, 0 confirmed, 0 refuted, 7 validator passes attempted, 0 failed. 1 file reviewed; 6 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to `done`.
  timestamp: 2026-09-03T21:43:11.227133+00:00
- actor: claude-code
  id: 01m1mkm0t347syzf1xhqjjzskg
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 1 file (ExtrasDemoIntegrationTests.swift); drain proved by measurement — 2 MB per stream concurrent 0.28-0.36s, sequential still blocked at 25s
    - test: green — `swift package reset && swift test`, 251 tests, 23 suites, 0 failed, 0 warnings, no hang
    - commit: 75addea fix(tests): drain both extras-demo output pipes at the same time
    - review: clean — 0 findings, 7 validator passes
    - next: task is in done; loop moves to ^h7w4n8r
  timestamp: 2026-09-03T21:43:24.739543+00:00
position_column: done
position_ordinal: 9b80
title: Split stdout and stderr in the extras-demo test harness
---
## What

`Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift` gives its
subprocess **one** pipe for both streams:

```swift
let outputPipe = Pipe()
process.standardOutput = outputPipe
process.standardError = outputPipe
```

`RunResult` then holds only `output` and `exitCode`. With this harness, no
test can prove that a command wrote to stdout and not to stderr. The doctor
demo task needs exactly that proof, because `doctor-plan.md` §6 puts the
table on stderr and the JSON on stdout.

This task changes only the harness. It adds no new test of its own, and it
must keep every test that is there now green.

Changes in `ExtrasDemoIntegrationTests.swift`:

- Give the process two pipes, one for `standardOutput` and one for
  `standardError`.
- Widen `RunResult` to `stdout`, `stderr`, and `exitCode`. Keep a computed
  `output` that joins `stdout` and `stderr`, so each call site that is there
  now continues to compile and to pass.
- **Drain the two pipes at the same time.** A read of stdout to its end,
  while the 64 KB buffer of stderr fills, is a deadlock. This is the reason
  the one-pipe harness is there today. Read each handle in its own child of
  a `withTaskGroup`, or with `readabilityHandler` and a `DispatchGroup`,
  and only then call `waitUntilExit()`.

Write in the doc comment of `run(arguments:)` why the two pipes must drain
at the same time, so a later change does not put the deadlock back.

## Acceptance Criteria

- [ ] `RunResult` holds `stdout`, `stderr`, and `exitCode`, and a computed
      `output` that joins the two streams.
- [ ] Each call site that is there now is unchanged, or it moved to the
      exact stream it asserts on.
- [ ] The subprocess reads run at the same time, and not one after the
      other.
- [ ] No test hangs. The full run of the suite ends.

## Tests

- [ ] Run `swift test --filter ExtrasDemoIntegrationTests`. Expect every
      test that is there now to pass, with no hang.
- [ ] Add one test that pins the split: a command that is known to write to
      stdout (for example `extras-demo stack` over the fixtures) gives a
      `stdout` that is not empty, and the same run gives a `stderr` that
      holds no part of that stdout text.
- [ ] Run `swift test`. Expect the full suite to pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.