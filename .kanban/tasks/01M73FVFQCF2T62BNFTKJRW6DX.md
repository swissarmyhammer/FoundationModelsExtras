---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73jvm7prfwer0tbavmqne9e
  text: |-
    Research done.
    - EmbedTelemetry.traceEmbed is the pattern: TracedCall.run with a model.ref attribute and log metadata, metrics made at call time, the duration timer records on the success path and on the error path with the model.outcome dimension (ModelOperationOutcome).
    - All telemetry names live in ExtrasTelemetry (SpanName, AttributeKey, MetricName). The new names go there.
    - docs/REFERENCE.md and README.md list no span names and no metric names, thus no doc change.
    - FakeLogits (ModelPoolTestSupport.swift) never throws. The error-path test needs a fake that throws: add a `failsLogProbabilities` flag with a default of false, so the memberwise init of the current callers stays the same.
    - TelemetryCapture.run(forbidding:) checks span attributes, log metadata and metric dimensions, not metric values. Token IDs are numbers: the test uses 9-digit IDs, so a hex trace ID or span ID cannot hold one by chance.
    - Decision: the duration timer also has the model.outcome dimension, the same as the embed and generate timers. The call counter has the model.ref dimension only.
  timestamp: 2026-11-10T20:37:11.030119+00:00
- actor: claude-code
  id: 01m73k4058z4m9qdar5snfy051
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift (new), Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift (span name `FoundationModelsExtras.logits`, attributes `logits.prompt_count`, `logits.candidate_count`, `logits.token_count`, metrics `FoundationModelsExtras.logits.calls` and `FoundationModelsExtras.logits.duration`, docs of the outcome and the dimensions), Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift (logProbabilities goes through LogitsTelemetry), Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift (new, 10 tests), Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift (FakeLogits.failsLogProbabilities, LogitsTelemetryExpectations). RED: 7 of 10 failed for the missing span and metrics. GREEN: `swift test --filter "LogitsTelemetry|PooledLogitsModel"` gave 25 tests in 2 suites passed. `swift build --build-tests` gave no warnings.
    - notes: the span holds the model load when the call loads the model. The duration timer also has the model.outcome dimension, the same as the embed timer. No doc lists telemetry names, thus no README or REFERENCE change. No other package calls PooledLogitsModel.
    - next: /review
  timestamp: 2026-11-10T20:41:45.384377+00:00
- actor: claude-code
  id: 01m73kat9mx084kjhvzf4en9vp
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (124f749), 3 findings (3 confirmed, 0 refuted) — Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift:81, Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift:91, Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift:85
    - next: implement the 3 findings in the "Review Findings (2026-11-10 14:43)" section, then review again.
  timestamp: 2026-11-10T20:45:28.756135+00:00
- actor: claude-code
  id: 01m73kbbp3yyp8sft5tykcqbx5
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files
    - test: green — swift test, 1833 + 13 passed, 0 failed
    - commit: 124f749
    - review: findings — Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift:81, Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift:91, Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift:85
  timestamp: 2026-11-10T20:45:46.563945+00:00
- actor: claude-code
  id: 01m73kjzvw07wedxy6g0zeh4k2
  text: |-
    Review findings done.
    - New file Sources/FoundationModelsExtras/Telemetry/ModelMetrics.swift: `extension ExtrasTelemetry` with `modelDimensions(of: ModelRef)` and `recordModelDuration(on:dimensions:outcome:since:)`. The timer helper takes the dimensions, not a ModelRef, because the load timer of ModelLoadTelemetry also has the model.role dimension. EmbedTelemetry and LogitsTelemetry pass `modelDimensions(of: ref)`. ModelLoadTelemetry passes its key dimensions, which now start from `modelDimensions(of: key.ref)`.
    - The private `dimensions(of:)` of EmbedTelemetry and LogitsTelemetry, the private `modelDimensions(of:)` of PoolTelemetry, and the private `recordDuration` of EmbedTelemetry and LogitsTelemetry are deleted. Metric names, dimension keys and dimension order did not change.
    - LogitsTelemetryTests: `captureOneCall()` has no catch now. The call error goes to the test, and the helper gives the rows. `captureOneFailedCall()` has its own capture and uses `await #expect(throws: FakeModelRunError.self)` on the call. Proof: with a throwing FakeLogits in `captureOneCall`, all 6 success tests failed with "Caught error: FakeModelRunError()". Then the change was reverted.
    - Not changed: GenerateTelemetry has a private `dimensions` property with the same model-ref dimension. The findings did not name it.
  timestamp: 2026-11-10T20:49:56.604602+00:00
- actor: claude-code
  id: 01m73kk8322tmvnvvkx0j9addj
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/Telemetry/ModelMetrics.swift (new), Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/ModelLoadTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/PoolTelemetry.swift, Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift. `swift test --filter "Telemetry|PooledLogitsModel"`: 99 tests in 15 suites passed, 0 failed. `swift test --filter "ModelPool|Pool|Embed|ModelLoad"`: 252 tests in 14 suites plus 10 tests in 2 suites passed. No compiler warnings.
    - next: /review
  timestamp: 2026-11-10T20:50:05.026882+00:00
- actor: claude-code
  id: 01m73kr2phhb222rn7dwj0hy8b
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (43522bb). 1 finding (1 confirmed, 3 refuted). Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift:71. The 3 findings of 2026-11-10 14:43 are all checked.
    - next: implement the finding of 2026-11-10 14:51. Put one helper in ModelMetrics.swift that runs the body, records the timer with .succeeded or .failed, and rethrows. Call it from traceEmbed and traceLogProbabilities.
  timestamp: 2026-11-10T20:52:43.345081+00:00
- actor: claude-code
  id: 01m73krq6d7rqgh5rhmyand2ge
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 6 files
    - test: green — swift test, 7 runs, 0 failed
    - commit: 43522bb
    - review: findings — Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift:71
  timestamp: 2026-11-10T20:53:04.333459+00:00
- actor: claude-code
  id: 01m73kzzhnvgxqrdwm910xw37n
  text: |-
    Finding of 2026-11-10 14:51 done.
    - ModelMetrics.swift has 2 new helpers. `timeModelOperation(on:dimensions:since:_:)` runs the body, records the timer with .succeeded or .failed, and rethrows. `recordingOutcome(of:record:)` is the do/catch: it runs the body and gives the outcome to a record closure. `timeModelOperation` uses it.
    - traceEmbed, traceLogProbabilities and ModelLoadTelemetry.traceLoad call `timeModelOperation`. The private `recordLoadDuration` of ModelLoadTelemetry had no caller after this, thus it is deleted. `recordDuration` stays for the evict timer.
    - GenerateTelemetry.traceGenerate had the same do/catch outcome pair, but its record writes 2 timers and the token metrics. It now calls `recordingOutcome(of:record:)` with `call.record(outcome:)`.
    - No do/catch outcome pair stays in the Telemetry folder. The catches in GenerateChannelRelay and TracedCall are of a different kind (relay of a failure, span error status).
    - New test file Tests/FoundationModelsExtrasTests/Telemetry/ModelMetricsTests.swift, 5 tests. RED: a compile error, "type 'ExtrasTelemetry' has no member 'timeModelOperation'". GREEN: 5 of 5 passed.
    - Metric names, dimension keys and dimension order did not change.
  timestamp: 2026-11-10T20:57:02.261841+00:00
- actor: claude-code
  id: 01m73m02z0be70tsca2xyabacg
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/Telemetry/ModelMetrics.swift, Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/ModelLoadTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/GenerateTelemetry.swift, Tests/FoundationModelsExtrasTests/Telemetry/ModelMetricsTests.swift (new). `swift test --filter "Telemetry|PooledLogitsModel|Embed|ModelLoad|Generate"`: 248 tests in 23 suites, 9 tests in 1 suite, 4 tests in 1 suite, 1+1 tests passed, 0 failed. `swift build --build-tests`: no compiler warnings.
    - next: /review
  timestamp: 2026-11-10T20:57:05.760104+00:00
depends_on:
- 01M73FTQ8MB6JSDYYR9BYWJHBD
position_column: doing
position_ordinal: '8180'
title: 'LogitsTelemetry: one span and metrics for each logProbabilities call'
---
## What
Record telemetry for each `logProbabilities(of:after:)` call of `PooledLogitsModel` (`Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`). Put the trace in `PooledLogitsModel`, so that each backend (MLX and llama.cpp) gets it with no extra code.

Create `Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift`. Use the same pattern as `EmbedTelemetry` in `Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift`: the span goes through `TracedCall`, and the metrics are made at call time, so that they use the metrics factory of the current task.
- [x] `enum LogitsTelemetry` with `static func traceLogProbabilities(of ref: ModelRef, candidates: [Int], prompts: [[Int]], body: …) async throws -> [[Double]]`.
- [x] One span for each call, with the attributes `model.ref`, `logits.prompt_count`, `logits.candidate_count` and `logits.token_count` (the sum of the prompt lengths). On an error, the span records the error.
- [x] Metrics: a call counter and a duration timer, with the `model.ref` dimension. Record the duration on the success path and on the error path.
- [x] The span and the metrics contain no prompt text and no token IDs.
- [x] `PooledLogitsModel.logProbabilities` calls `LogitsTelemetry.traceLogProbabilities`.

## Acceptance Criteria
- [x] One `logProbabilities` call with 3 prompts of 4, 5 and 6 tokens and 2 candidates gives one span with `logits.prompt_count` 3, `logits.candidate_count` 2 and `logits.token_count` 15.
- [x] The call counter increments by 1 and the timer records 1 value, also when the call throws.
- [x] No attribute of the span holds prompt text or token IDs.

## Tests
- [x] Create `Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift`, with the same capture helpers as `Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift`. Add a `LogitsTelemetryExpectations` enum next to `EmbedTelemetryExpectations` in `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift` when this helps. Use the `FakeLogits` stub of the PooledLogitsModel tests. Test the success path, the error path and the absence of text and token IDs.
- [x] Run `swift test --filter LogitsTelemetry`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision

## Review Findings (2026-11-10 14:43)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift:81` `reuse/reuse` — The new recordDuration(of:outcome:since:) rebuilds the same model-outcome timer write that already exists in EmbedTelemetry and ModelLoadTelemetry. A second copy lets the logits timer drift from the others. Move one shared helper that takes a label, a ModelRef, an outcome and a start instant into a file that all three callers can reach, for example as an internal static in ExtrasTelemetry or in a shared telemetry helper. Then call it from LogitsTelemetry, EmbedTelemetry and ModelLoadTelemetry.
- [x] `Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift:91` `reuse/reuse` — The new dimensions(of:) returns the model ref as the only metric dimension. That is the same function, byte for byte, as the private helpers that already exist for embed and pool metrics, so it is a duplicate. Keep one internal helper that gives the model-ref dimension for a ModelRef, and use it from LogitsTelemetry, EmbedTelemetry and PoolTelemetry. Delete the private copies.
- [x] `Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift:85` `test-integrity/no-test-cheating` — The catch in captureOneCall turns a thrown error from logProbabilities into a .failure value. Four success-path tests discard that value with `let (context, _)`, so they pass even when the call throws. aCallOpensOneSpan, theSpanHasTheCounts and aCallIncrementsTheCallCounter would stay green on a failed call. The failure is swallowed rather than proven, which breaks the rule that every test must be able to fail. Make captureOneCall take an expectation of success, for example by calling model.logProbabilities directly in the success tests with `try`. Or have each success test assert `try outcome.get()` is non-throwing before it checks spans or counters. Keep the catch only in captureOneFailedCall's path, where #expect(throws:) proves the error.

## Review Findings (2026-11-10 14:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift:71` `duplication/duplication` — The success and failure timer pair (do/catch, with recordModelDuration called once per outcome) is copied in traceEmbed and in traceLogProbabilities. Only the timer name and the outcome differ. The copies can drift, for example if one gets a dimension and the other does not. Add one helper in ModelMetrics.swift that takes the timer label, the dimensions, the start instant and a body closure. The helper runs the body, records the timer with .succeeded or .failed, and rethrows. Both traceEmbed and traceLogProbabilities then call it, and each keeps only its own body.
