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
- actor: claude-code
  id: 01m3hqt3x7vxfc0w7z0tck31gf
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` gave 1 finding (1 confirmed, 1 refuted): Sources/FoundationModelsExtras/Hosting/RunToCompletionRunner.swift:49 `duplication/duplication`. All 6 acceptance criteria are ticked: the 4 new tests are in PerCallMountTests.swift, the commit changes no existing test, `swift build --build-tests` gives 0 warnings, and `swift test` passes (731 tests in 70 suites, and the other test runs).
    - next: /implement the finding, then /review again.
  timestamp: 2026-09-27T15:30:19.175704+00:00
- actor: claude-code
  id: 01m3hqte5r1acx7t4zzepnqe50
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 Hosting sources, PerCallMountTests.swift, README, CHANGELOG
    - test: green — swift test, 731 tests in 70 suites
    - commit: cb3f6d4
    - review: findings — Sources/FoundationModelsExtras/Hosting/RunToCompletionRunner.swift:49
  timestamp: 2026-09-27T15:30:29.688483+00:00
- actor: claude-code
  id: 01m3hr1p63zr13t17f63gtg92y
  text: |-
    Finding RunToCompletionRunner.swift:49 `duplication/duplication` is fixed.
    - New internal protocol `MountRunner` in ToolMounting.swift. Each runner sets only `static var defaultMode` (`.runToCompletion` or `.background`) and its three stored properties.
    - The protocol extension holds the one shared `call(arguments:)`, which calls `ToolMounting.call(_:arguments:site:mount:)` with `ToolMount(mode: Self.defaultMode, timeout: timeout)`.
    - Other copies with the same cause are also removed from the two runner files: the `name`/`description`/`parameters`/`includesSchemaInInstructions` forwarders and the `init(wrapping:site:timeout:)` body. The shared `init(wrapping:)` calls the memberwise initializer.
    - `site` changed from `private` to internal, because the protocol requires it.
    - Note: `review dump validators` gave a rules file of 730K characters. It was too large to read, so I applied the usual rules (doc comments, no copies, small functions).
  timestamp: 2026-09-27T15:34:27.267902+00:00
- actor: claude-code
  id: 01m3hr1w0yv8xasz484ttgzenb
  text: |-
    ### implement — changed
    - evidence: ToolMounting.swift, RunToCompletionRunner.swift, BackgroundToolRunner.swift. `swift build --build-tests` and `swift build` give 0 warnings. `swift test` passes: 731 tests in 70 suites, plus 396, 125, 44, 34 and 26 in the other runs. Commit 23e0f9c (local, not pushed). The comment and step record after the commit are not in that commit.
    - next: /review
  timestamp: 2026-09-27T15:34:33.246745+00:00
- actor: claude-code
  id: 01m3hr61e5es3fh561rz64efvb
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (23e0f9c): 0 findings, 7 validator runs, 0 failed. All prior findings are checked.
    - next: none. The task is in done.
  timestamp: 2026-09-27T15:36:49.861707+00:00
- actor: claude-code
  id: 01m3hr67zmpxkvh60xs6czfsnk
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — ToolMounting.swift, RunToCompletionRunner.swift, BackgroundToolRunner.swift (one shared call)
    - test: green — swift test, 731 tests in 70 suites
    - commit: 23e0f9c
    - review: clean — 0 findings; task in done
  timestamp: 2026-09-27T15:36:56.564268+00:00
position_column: done
position_ordinal: c780
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
- [x] Test: a tool whose `mount(for:)` returns `.background` for one argument and synchronous for another; each call gets the correct behavior.
- [x] Test: the synchronous call returns its real output also when it takes longer than `inlineSettleGrace`.
- [x] Test: the background call returns a token also when its work ends at once.
- [x] Test: a nested `.background` mount from a synchronous call posts its terminal to the sink as staged mail.
- [x] Test: a tool with no `mount(for:)` override behaves as before (the existing tests pass with no change).
- [x] `swift build` 0 warnings; `swift test` passes.

#tool-hosting #cross-repo

## Review Findings (2026-09-27 10:22)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `CHANGELOG.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsExtras/Hosting/RunToCompletionRunner.swift:49` `duplication/duplication` — The `call(arguments:)` method is verbatim duplicated in BackgroundToolRunner.swift with only the mount mode parameter differing (.runToCompletion vs .background). This is copy-paste that should be a single shared function parameterized by the mode. Extract a shared helper function `call(arguments:mode:)` that takes the ToolMount.Mode as a parameter, and call it from both BackgroundToolRunner and RunToCompletionRunner with their respective modes. Delete the duplicate implementations.
