---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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