---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
title: Drain both pipes at the same time in IgnoreGitParityTests' git harness
---
## What

`Tests/FoundationModelsExtrasTests/IgnoreGitParityTests.swift`, in
`runCheckIgnore(probePaths:repoURL:)`, reads its two pipes one after the
other:

```swift
let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
```

A pipe holds about 64 KB before it blocks its writer. Reading standard
output to its end first deadlocks the moment `git check-ignore` writes more
than that to standard error: git blocks on a full standard-error pipe and
never closes standard output, so the first read never reaches end of file.

The suite does not hang today only because `git check-ignore` output over
the corpus stays small. The deadlock is latent, not absent. A measurement
made while task ^vxj3x17 was implemented confirms the shape: a child that
writes 2 MB to standard error still blocked a sequential reader after 25
seconds, while a concurrent drain of the same load finished in 0.36
seconds.

Found while task ^vxj3x17 removed the same fault from
`ExtrasDemoIntegrationTests.swift`. It was left alone there because that
card named one file.

## What to do

- Drain the two handles at the same time, not one after the other, and
  only then call `waitUntilExit()`.
- Reuse the shape that `ExtrasDemoIntegrationTests.swift` now uses: a
  `readabilityHandler` for each handle, a `DispatchGroup` that both join,
  and a `final class ... : Sendable` holding a `Mutex<Data>` to collect the
  bytes. That shape keeps the function synchronous, so no call site moves.
- Check `run(arguments:currentDirectory:)` in the same file as well. It
  reads its error pipe only after `waitUntilExit()`, and gives standard
  output a `Pipe()` that nothing ever drains.

## Acceptance Criteria

- [ ] Neither subprocess helper in the file reads one stream to its end
      before the other one is being drained.
- [ ] Every test in the file that passes today still passes.
- [ ] `swift test` ends. It does not hang.