---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4r7t9m55vkpqr487vj7xvr3
  text: |-
    Research (implement):
    - `LanguageModelExecutorGenerationChannel` is an `AsyncThrowingChannel` (rendezvous): `send` returns only when a reader takes the event. It has a public `init()` but no public `finish()`, and a cancelled reader ends its loop. Thus the wrap gives the model a new channel, a pump child reads it into an `AsyncStream`, and a forwarder sends each event to the outer channel. When the model returns, the pump is cancelled (each event was already taken), the stream finishes, and the forwarder drains it. No event is lost.
    - `Event` has no public accessors. A `Mirror` walk finds the public `Usage` value of an `updateUsage` event (MLX sends `updateUsage`, last write wins; the mlx-swift-lm tests read events by `Mirror` too). The token counts come only from `Usage.output.totalTokenCount`.
    - `PooledSession` runs a `LanguageModelSession` over the container model, not over `PooledModel`. To see its channel, the session must run over a wrapper model that relays the channel into the generate call of the running respond.
    - In the `PooledModel` path, `LanguageModelSession` calls the executor one time for each model round. Tools run between the rounds, outside the executor call. In the `PooledSession` path, the tools run inside `session.respond`, inside the queue job, thus inside the generate span.
    - `generate.cold` needs to know that the call waited for the load and that the pool acquire loaded the model (not a hit). Plan: `ModelHold` keeps its `PoolCacheResult`, and `ResidentHold` tells whether the call waited for the load.
  timestamp: 2026-10-12T14:21:10.661494+00:00
- actor: claude-code
  id: 01m4r8e3qprswqvz0wqgj1xdxv
  text: |-
    Implementation landed (TDD: 11 new tests failed first, then passed).
    - New `Telemetry/GenerateTelemetry.swift`: `GenerateTelemetry.traceGenerate(of:guided:_:)` opens the generate span through `TracedCall` and records the duration timer and the time-to-first-token timer with `model.ref` and `model.outcome` on the success path and on the error path (the EmbedTelemetry pattern). `GenerateCall` relays each model round (pump into an `AsyncStream`, forwarder to the session channel), records the first event, and adds the output tokens of the last `updateUsage` of each round. Tokens per second = output tokens / sum of the round times; it is recorded only when a round gave a usage and the model time is not zero.
    - New `ModelPool/GenerateRelayModel.swift`: `PooledSession` now runs its `LanguageModelSession` over `GenerateRelayModel` (the container through `ExecutableLanguageModel`, now internal). `GenerateCallSlot` holds the generate call of the respond call that runs.
    - `generate.cold`: `ModelHold.cacheResult` (internal) and `ResidentHold.loadedReportingWait()`. Cold = the call waited for the hold load AND that acquire loaded the model (a pool hit is warm). A call whose load throws is cold. A `PooledSession` respond is never cold, because the session acquired its hold before the call.
    - Decision to note: on the `PooledModel` path, `generate.guided` is `request.schema != nil`, so `LanguageModelSession.respond(generating:)` over a pooled model is guided too. On the `PooledSession` path it is `true` for `respond(to:generating:)`, as the card says.
    - Limit to note: on the `PooledModel` path, a `LanguageModelSession` calls the executor one time for each model round and runs the tools between the rounds, thus each round is its own generate span and a tool span there is not inside a generate span. On the `PooledSession` path the tools run inside the respond call, thus the tool span is a child of the generate span (tested).
    - Vocabulary in `ExtrasTelemetry.swift`: `SpanName.generate`, `AttributeKey.generateGuided`/`generateCold`, four `MetricName.generate*` names, `PoolLogMessage.generateRelayFailed` (written by `PoolTelemetry.logGenerateRelayFailure` when the model channel throws, with `assertionFailure`).
    - `swift test`: 1030 tests in 91 suites passed (11 known issues are the existing withKnownIssue cases of TelemetryCaptureTests); no warning from this repo (only the mlx-swift_Cmlx.bundle line).
  timestamp: 2026-10-12T14:31:59.990748+00:00
- actor: claude-code
  id: 01m4r8eb3ncj8fmg3d3npqze6n
  text: |-
    ### implement — changed
    - evidence: `swift test` = 1030 tests in 91 suites passed, 0 failures (11 known issues are the existing withKnownIssue cases of TelemetryCaptureTests). `swift test --filter PooledModelTests` = 30 tests passed. Correction to the comment above: 11 new tests ran first and 10 failed (the "no token counts" test passed at RED, because it checks for an absence); the cold-false test for a resident model came after the implementation. Files: Sources/FoundationModelsExtras/Telemetry/GenerateTelemetry.swift (new), Sources/FoundationModelsExtras/ModelPool/GenerateRelayModel.swift (new), Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/PoolTelemetry.swift, Sources/FoundationModelsExtras/ModelPool/PooledModel.swift, Sources/FoundationModelsExtras/ModelPool/PooledSession.swift, Sources/FoundationModelsExtras/ModelPool/ModelPool.swift, Sources/FoundationModelsExtras/ModelPool/ResidentHold.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/ModelPool/StubLanguageModel.swift
    - next: /review
  timestamp: 2026-10-12T14:32:07.541457+00:00
- actor: claude-code
  id: 01m4r91kk7bgvr9bcp8jx96hwb
  text: |-
    ### review — findings
    - evidence: review sha b5bada1~1..b5bada1 — 1 finding (1 confirmed, 1 refuted). Sources/FoundationModelsExtras/ModelPool/GenerateRelayModel.swift:74
    - next: /implement the open item in the Review Findings (2026-10-12 09:38) section
  timestamp: 2026-10-12T14:42:38.823634+00:00
- actor: claude-code
  id: 01m4r91mrrmk24rqq8t3sb8p33
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files
    - test: green — swift test, 1030 passed; IntegrationTests, 37 passed
    - commit: b5bada1
    - review: findings — Sources/FoundationModelsExtras/ModelPool/GenerateRelayModel.swift:74
  timestamp: 2026-10-12T14:42:40.024271+00:00
- actor: claude-code
  id: 01m4r9fagzdcsqkh2h648x6m6x
  text: |-
    Finding fixed: `GenerateRelayExecutor.Configuration.slot` was written and never read. Only the synthesized `Hashable` read it, and only the executor cache of FoundationModels uses that key. The executor holds no state (the model and its slot arrive with each call), thus a key per session gave nothing. The field is removed: `Configuration` is now an empty `Hashable` struct, and `executorConfiguration` gives `Configuration()`. The doc comments say why the key has no field. `GenerateRelayModel.slot` stays, because `respond` reads `model.slot.current`.
    Whole-file check of GenerateRelayModel.swift and GenerateTelemetry.swift: no other property, parameter or local is written and never read. Only `init(configuration:)` does not read its parameter, and the `LanguageModelExecutor` protocol requires that signature (the dead-code-swift rule drops `var.parameter`).
    Note: a local periphery scan did not run. The default build system writes no index store, and `--build-system native` cannot build this package (the build stops with "error: cancelled"). The review step runs periphery.
    Not in scope, for the next agent: `PooledModelExecutor.Configuration.key` in PooledModel.swift has the same shape (only the synthesized Hashable reads it). The review did not flag it.
  timestamp: 2026-10-12T14:50:08.287446+00:00
- actor: claude-code
  id: 01m4r9fczp2ewsrww62xwe1y8p
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsExtras/ModelPool/GenerateRelayModel.swift. `swift test --filter 'PooledModel|PooledSession'` = 30 tests passed. `swift test` = 1030 tests in 91 suites passed (11 known issues are the existing withKnownIssue cases). `swift test --package-path IntegrationTests --filter 'ToolHosting|PooledSession|ModelPool'` = 17 tests in 4 suites passed. Only warning is the known mlx-swift_Cmlx.bundle line.
    - next: /review
  timestamp: 2026-10-12T14:50:10.806695+00:00
- actor: claude-code
  id: 01m4r9t3273z91j0cn5gtjcra9
  text: |-
    ### review — clean
    - evidence: review sha 91780bf~1..91780bf — 0 findings (0 confirmed, 0 refuted). 1 file reviewed. The prior finding in Review Findings (2026-10-12 09:38) is checked.
    - next: none. The task is in done.
  timestamp: 2026-10-12T14:56:01.095836+00:00
- actor: claude-code
  id: 01m4r9t4jesw0rqqykh7jrzftg
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file
    - test: green — swift test, 1030 passed; IntegrationTests, 37 passed
    - commit: 91780bf
    - review: clean — 0 findings
  timestamp: 2026-10-12T14:56:02.638375+00:00
depends_on:
- 01M4NYFBJJHE656GQR76E1AESD
position_column: done
position_ordinal: fa80
title: 'Generate telemetry: a span for each model call with time to first token, tokens per second and cold or warm'
---
## What

A model call has no span and no metric. The operator cannot see the time to the first token, the speed of the model, or whether a call had to load the model first.

The integration test with the real LLM is in task `ac35ek3`.

Files and points:
- `Sources/FoundationModelsExtras/ModelPool/PooledModel.swift`: `PooledModel.respond(to:streamingInto:)` (`:91`). It loads the model with `resident.loaded()` (`:95`), then submits the call to the model queue (`loaded.hold.queue.submit`, `:96-98`). `PooledModelExecutor.respond(to:model:streamingInto:)` (`:144`) calls it.
- `Sources/FoundationModelsExtras/ModelPool/PooledSession.swift`: `respond(to:)` (`:64`) and `respond(to:generating:)` (`:80`, the guided call) submit the session call to `hold.queue`.

Approach (each name in `ExtrasTelemetry.swift`, metric objects made at call time):
- Span `FoundationModelsExtras.generate` through `TracedCall`, so that a hung call has an "enter" record. Attributes: `model.ref`, `generate.guided` (`true` for `respond(to:generating:)` at `:80`, else `false`), and `generate.cold` (`true` when the call included a load, else `false`). Do not use the `cache.result` key here: `cache.result` keeps only the values `hit`, `late_hit` and `load` of task `556w4rs`.
- Open the span before the load and the queue wait, so that it is the parent of the load span (task `8r1175p`, when it exists) and each tool span that opens in the call. The queue wait is a metric (`FoundationModelsExtras.queue.wait`, task `7s472c8`), not a span. Task `7752wag` carries the `ServiceContext` into the detached queue job; this task depends on it.
- Wrap the `LanguageModelExecutorGenerationChannel` to see the first event and the end:
  - Timer `FoundationModelsExtras.generate.time_to_first_token` (from the span start to the first event) and Timer `FoundationModelsExtras.generate.duration`, both with `model.ref`.
  - When the channel gives token counts: Counter `FoundationModelsExtras.generate.output_tokens` and Recorder `FoundationModelsExtras.generate.tokens_per_second`, both with `model.ref`. When the channel gives no counts, record neither.
- Never record the prompt, the instructions, the transcript or the output text.

## Acceptance Criteria
- [x] Each model call opens one `FoundationModelsExtras.generate` span with `model.ref`, `generate.guided` and `generate.cold`, and writes one "enter" log record.
- [x] The first call after a load records `generate.cold=true`. A later call records `generate.cold=false`.
- [x] Each call records `FoundationModelsExtras.generate.time_to_first_token` and `FoundationModelsExtras.generate.duration`. When the channel gives token counts, the call records `FoundationModelsExtras.generate.output_tokens` and `FoundationModelsExtras.generate.tokens_per_second`.
- [x] The load span and each tool span of the call have the generate span as their parent.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`: with `StubLanguageModel.swift` and a fake loader, `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test the span, the attributes, cold and warm, the timers, and a stub that gives token counts and one that gives none.
- [x] A parent test: a tool span that opens inside the call has the generate span as its parent.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the prompt and the output text. The test also asserts that the capture saw at least one record.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature

## Review Findings (2026-10-12 09:38)

> Scope: `review sha b5bada1~1..b5bada1` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsExtras/ModelPool/GenerateRelayModel.swift:74` `code-hygiene/dead-code-swift` — var.instance `slot` is assignOnlyProperty.
