---
position_column: todo
position_ordinal: '8580'
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

- [ ] `ProcessRunner` gives the behavior of the runner that moved: the process group, the merged output, the timeout, the `SIGKILL` of the group, and the tail of the output.
- [ ] The pid is registered before the wait and deregistered after the reap, also on the timeout path and on the error path.
- [ ] A process that writes without end does not grow the memory of the caller: the read stops at the byte limit.
- [ ] A process that ends on its own gives its exit code; a process that passes the timeout gives the timeout result.
- [ ] No type of `ProcessRunner` names a skill, a marketplace or a dotfolder.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift` (new): a command that ends gives its exit code and its output.
- [ ] Same file: a command that sleeps longer than the timeout gives the timeout result, and the group is gone after the call.
- [ ] Same file: a command that writes more than the byte limit gives the tail, with the mark, and the memory does not hold the full output.
- [ ] Same file: the registry holds the pid while the process runs, and holds nothing after the call, for the normal path and for the timeout path.
- [ ] Same file: a child that makes a child of its own is also killed, because the kill goes to the group.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#process-safety #cross-repo