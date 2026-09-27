---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hmtb93d3wvjzhh3hhjsb6t
  text: |-
    ### Added requirement (2026-09-27)
    This task now runs after the per-call mount tasks (01M3HMSR0XDGD54R903GZHCJP3 and 01M3HMSWFHGNG82AS532BY8WVB), so that the real-model tests cover the new behavior.
    - [ ] Test: one tool whose `mount(for:)` returns `.background` for one argument and synchronous for another, under a real model session. The model gets a pending token for the background call, and the real result in-band for the synchronous call.
    - [ ] Test: an `OperationTool` with one background operation and one synchronous operation, under a real model session.
  timestamp: 2026-09-27T14:38:00.995321+00:00
- actor: claude-code
  id: 01m3hsdr4bwpywxgye4m030fpx
  text: |-
    ### Research (implement)
    - Model choice: MLX `mlx-community/Qwen3-4B-4bit` through the existing `ModelPool` + `MLXPooledLoader`. Reason: the FoundationModelsRouter tool-answer suite (`RealToolAnswerComparisonTests`) uses this model because it calls tools and answers fast (about 8 s for one answer). The Multitool bare-session suites use Apple Intelligence `.default`, but they SKIP when the model is not available. This package FAILS and does not skip (`ModelAvailability`), and CI has no Apple Intelligence. The 1B Llama of `IntegrationModels.llm` is too weak for tool calls. The HF cache on this machine holds the 4B already.
    - `RunPlane.cancel` is internal. The public cancel path is `ToolContext.cancel(completionToken:)` on a `ToolContext` that the host makes with the public init (session id, run plane, sink). The test uses that path.
    - A pending envelope tells the model to call a `wait` tool. The per-call tests mount a test `wait` tool that calls `ToolContext.current.wait`. The background and cancel tests give their own `collectInstruction`.
    - The model list of each session is `ToolFailureDelivery.makeWrapped(ToolMounting.makeWrapped(...))`, as the Extras docs say for a host. Without it a throw ends the model call.
    - The `OperationTool` test needs the `Operations` product in `IntegrationTests/Package.swift`.
    - A tool that ignores cancel: `await Task.detached { try? await Task.sleep(...) }.value` (a detached task does not get the cancel, and there is no busy loop).
  timestamp: 2026-09-27T15:58:31.051578+00:00
- actor: claude-code
  id: 01m3htn4fkp5nx89dqv5c8q4ey
  text: |-
    ### Implementation landed
    - New suite `RealModelSuites.ToolHostingIntegrationTests` (8 tests): run to completion, background run + settlement observer, grace wait, cancel, timeout, failure delivery, per-call mount of one tool, per-call mount of an `OperationTool`.
    - New support: `Support/ToolHost.swift` (session id, `RunPlane`, event sink; mounts with `ToolMounting.makeWrapped` inside `ToolFailureDelivery.makeWrapped`; cancel through a host `ToolContext`), `Support/ToolSession.swift` (loads Qwen3-4B through the pool, one `LanguageModelSession`, greedy, `/no_think`, reads the tool outputs from the transcript). Fixtures in `ToolHostingFixtures.swift`.
    - `EventLog<OperationEvent>` conforms to `OperationEventSink` and `BackgroundRunSettlementObserver` (no new sink type).
    - `MLXPooledLoader` now takes `languageModelCapabilities`. Discovery: an `MLXLanguageModel` made with the default capabilities (`.guidedGeneration` only) makes `LanguageModelSession` throw "The selected model does not support tool calling". The tool-hosting session uses the Router's set `[.guidedGeneration, .toolCalling, .reasoning]`. `IntegrationModels.acquire` takes a `footprint` for the 4B model.
    - `IntegrationTests/Package.swift` links the `Operations` product.
    - Red check: with `JobTool.mount(for:)` forced to `.synchronous`, the per-call test failed at `!pending.isEmpty`. Restored after.
    - Note: swiftformat `swiftTestingTestCaseNames` wants raw-identifier test names. Every existing file of this package uses `@Test("...") func name()`, so the new suite follows the package pattern.
  timestamp: 2026-09-27T16:20:01.651719+00:00
- actor: claude-code
  id: 01m3htn6g6pm8v9vaj7gsr4x7a
  text: |-
    ### implement — changed
    - evidence: `swift test --package-path IntegrationTests` 3 runs in a row: 22 tests in 6 suites passed each time (67.8 s, 71.3 s, 64.9 s); the only warning is "missing creator for mutated node … mlx-swift_Cmlx.bundle". Root `swift build` clean; root `swift test` 1365 tests passed (131+37+44+26+396+731), 0 warnings. Files: IntegrationTests/Package.swift, Support/IntegrationModels.swift, Support/MLXPooledLoader.swift, Support/ToolHost.swift (new), Support/ToolSession.swift (new), ToolHostingFixtures.swift (new), ToolHostingIntegrationTests.swift (new).
    - next: /review
  timestamp: 2026-09-27T16:20:03.718835+00:00
depends_on:
- 01M3HD6T6P13MA52XSVQ8EEGJF
- 01M3HMSWFHGNG82AS532BY8WVB
position_column: doing
position_ordinal: '80'
title: 'Integration tests 4: real-model tests of tool hosting with a background tool'
---
## Why
The multitool uses tool hosting from Extras with a real model: the model calls a tool, the tool starts a background run, and the result comes back later. The unit tests drive `ToolContext`, `RunPlane` and the runners with scripted calls. These tests run them under a real FoundationModels `LanguageModelSession` in the nested `IntegrationTests/` package.

## What to do
Read how the Multitool and the Router integration suites drive a real session with mounted tools (`/Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/IntegrationTests/`, `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/IntegrationTests/`), and use the same model source (Apple Intelligence `.default` or the MLX model that those suites use; record the choice and why). Mount tools with the public Extras API only (`ToolMount`, `ToolMounting.makeWrapped`, `BackgroundTool`, `ToolContext`, `RunPlane`).

## Tests to add
- [ ] Run to completion: the model calls a mounted in-band tool, the tool reads `ToolContext.current`, posts progress, and returns; the model's answer uses the tool result.
- [ ] Background run: the model calls a `BackgroundTool`; the tool returns a pending envelope at once; the run settles later; `RunPlane.wait` gives the terminal; the settlement observer receives it.
- [ ] Grace wait: a fast background run settles inside the grace time, so the model gets the result inline and no pending envelope.
- [ ] Cancel: `RunPlane` cancel of a running background run gives the canceler's outcome, and the run settles with that outcome.
- [ ] Timeout: a mounted tool with a short timeout that ignores cancel gives `ToolMountError.timedOut` to the model at the deadline, and the model call does not hang.
- [ ] Failure delivery: a tool that throws gives the model a failure result, not a thrown error, and the session continues.
- Give each test a time limit. Simple test code; no lock/semaphore/gate types.

## Acceptance criteria
- [ ] `swift test --package-path IntegrationTests` passes on this machine, 3 runs in a row.
- [ ] The root `swift test` is unchanged and passes.

#integration-tests