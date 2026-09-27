---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hpx21tkq3sxrjan2dj5zbr
  text: |-
    Research:
    - `ToolMounting.makeWrapped` picks `BackgroundToolRunner` or `RunToCompletionRunner` one time for each tool, from `BackgroundTool.mount ?? configuration`. Existing tests read the runner type and its `timeout`, so the runner type from `makeWrapped` must stay the same.
    - Plan: one decision point for each call, `ToolMounting.call(_:arguments:site:mount:)`. Both runners send `call(arguments:)` through it. It asks `BackgroundTool.mount(for:)` (default: `mount`) and runs the call in the background or to completion.
    - Nested run today: `ToolContext.mount(_:op:as:)` gives the mounted tool a `MountedRunUpstreamSink`. A nested background run posts its terminal through the parent context. The parent funnel then takes it as the terminal of the PARENT run (it changes the parent terminal), or drops it when the parent already settled. Only the run plane observer gets it with its own token. So the terminal does not go to the session sink under its own token.
    - Fix: `MountSite` also holds the sink of the session for background calls. A background call uses that sink, so a nested background run is the same as a top-level background run. `ToolContext` keeps the session sink so a nested mount can give it on.
  timestamp: 2026-09-27T15:14:27.002373+00:00
- actor: claude-code
  id: 01m3hqa071ewp3aaw0x29k4trk
  text: |-
    Implementation landed.
    - `BackgroundTool.mount(for:)` returns `ToolMount?`, not `ToolMount`. Cause: the card says the default returns `mount`, and `mount` is `ToolMount?`. `nil` means "use the mount of the host", the same as `mount`. A non-optional return cannot hold that default.
    - One decision point: `ToolMounting.call(_:arguments:site:mount:)`. `BackgroundToolRunner.call` and `RunToCompletionRunner.call` both go through it; the old bodies are now `callInBackground` and `callToCompletion`. `makeWrapped` still picks the runner type from `mount ?? configuration`, so the existing tests that read the runner type and its timeout pass with no change.
    - `MountSite` has an internal `sessionSink`. A background call uses `site.postingToSession`. `ToolContext` keeps the session sink, and `mount(_:op:as:)` gives it to the nested site. Thus a nested background run posts its events and terminal to the session sink under its own token.
    - `ToolRun.timeout(of:for:)` now uses the shared `ToolMounting.backgroundDeclaration(of:for:)`.
    - `inlineSettleGrace` stays for background calls (no change for current tools). A synchronous call never waits for it.
    - README "Tool hosting" and CHANGELOG updated.
  timestamp: 2026-09-27T15:21:31.105287+00:00
- actor: claude-code
  id: 01m3hqa5rnrfk5j4h96qtn4bpa
  text: |-
    ### implement — changed
    - evidence: `swift build` complete with 0 warnings; `swift test` 731 tests in 70 suites passed (plus 396, 125, 44, 34, 26 in the other test runs), 0 issues. New suite `PerCallMountTests` (4 tests) failed first for the correct reasons, then passed. Files: BackgroundTool.swift, BackgroundToolRunner.swift, RunToCompletionRunner.swift, ToolContext.swift, ToolMounting.swift, ToolRun.swift, PerCallMountTests.swift, README.md, CHANGELOG.md. One local commit follows.
    - next: /review
  timestamp: 2026-09-27T15:21:36.789280+00:00
position_column: doing
position_ordinal: '80'
title: 'Tool hosting 6: a tool chooses background or synchronous for each call'
---
## Why
User direction (relayed 2026-09-27): "it's stupid that you made the 'tool' require being all background or not rather than the individual operation" and "list, check, cancel operations should be synchronous, meaning in their implementation you do not return until you get results. YOU have the choice to return a background token or not."
Today `ToolMounting.makeWrapped` (Sources/FoundationModelsExtras/Hosting/ToolMounting.swift) reads `(typed as? any BackgroundTool)?.mount ?? configuration` ONE time for the whole tool. The FoundationModelsAgents `agents` tool has 4 ops: `start agent` must return a background token, and `list`, `check`, `cancel` must run in-band and return their real result. Today the only way is to mount the whole tool `.background` and let fast ops settle inside `inlineSettleGrace`, which is a timeout, not a choice.

## What to do
1. `BackgroundTool` gets `func mount(for arguments: GeneratedContent) -> ToolMount`, with a default implementation that returns `mount`. Every current tool keeps its behavior.
2. The mounting code asks for the mount of EACH call, before the call runs:
   - A synchronous call runs in-band and returns its real output. There is no grace wait.
   - A background call returns the pending envelope, is tracked in the `RunPlane`, and its terminal goes to the sink as staged mail, the same as a background call today.
3. `ToolContext.mount(_:op:as: .background)` from inside a synchronous call: the started run must be a full background run whose terminal is POSTED to the session sink as staged mail (so it wakes the next submission), not only journaled. First check how a nested run reports its terminal in Extras today; then make it the same as a top-level background run.
4. Keep it simple: one decision point for each call, no new lock/semaphore/gate types, short doc comments. Update the README "Tool hosting" section.

## Acceptance criteria
- [ ] Test: a tool whose `mount(for:)` returns `.background` for one argument and synchronous for another; each call gets the correct behavior.
- [ ] Test: the synchronous call returns its real output also when it takes longer than `inlineSettleGrace`.
- [ ] Test: the background call returns a token also when its work ends at once.
- [ ] Test: a nested `.background` mount from a synchronous call posts its terminal to the sink as staged mail.
- [ ] Test: a tool with no `mount(for:)` override behaves as before (the existing tests pass with no change).
- [ ] `swift build` 0 warnings; `swift test` passes.

#tool-hosting #cross-repo