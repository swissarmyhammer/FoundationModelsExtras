---
assignees:
- claude-code
position_column: done
position_ordinal: ffca80
title: BackgroundRun records the call description, so a waiting status names what each run waits on
---
**Problem.** Multitool 6b0002c lists the open background calls in its no-op answer through `waitingStatusInstruction(for:)`. `BackgroundRun` has only `op`, so each call shows as `execute`, not `execute python tests/runtests.py …`. The model's status then says "Waiting on execute (01M…)", and the parent cannot tell from it what the child waits on.

**Change**
- Add `public let description: String` to `BackgroundRun`.
- `RunPlane.start` takes `description: String? = nil`. With nil, it uses the op.
- `BackgroundToolRunner` works out the description once: `callDescription(for:)`, or the op when that is nil. It passes that to the envelope and to `start`.

**Acceptance**
- [ ] A test shows that a run of a tool with `callDescription` lists that description in `backgroundRuns()`.
- [ ] A test shows that a run of a tool with no description lists its op.
- [ ] The full suite is green with zero warnings. Push main, and send the sha to the ACP session. #hosting