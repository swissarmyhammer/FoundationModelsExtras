---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ra027ctpxn9gvdgqxn51y5
  text: |-
    Research:
    - Only a `LanguageModelSession` over a `PooledModel` can give `generate.cold=true`. `PooledModel.respond` loads the model in the generate span and marks the call cold when it waited for a load that the pool ran. A `PooledSession` acquires its hold before the span, and `PooledSession` always marks `cold=false`. Thus the test runs two calls in one `LanguageModelSession` over one `PooledModel`.
    - The load span of the first call is a child of the first generate span (the queue job restores the trace context). The test can check that parent id.
    - The timers have the dimensions `model.ref` then `model.outcome`. To read them, the test uses `TestMetrics.expectTimer` from `MetricsTestKit`. The IntegrationTests package did not name `swift-metrics`, thus the manifest gets `MetricsTestKit` (the resolved file already holds swift-metrics 2.11.0).
    - `TelemetryCapture.run(forbidding:)` takes the forbidden strings before the body. The answers are known only after the calls, thus the test calls `context.leaks(forbidding:)` with the answers after the run.
    - The answers must contain a real word: a one-character answer would match hex ids in the log metadata. The test requires each answer to contain "paris".
    - New shared span query `CapturedSpans.spans(named:in:)` in `Support/CapturedSpans.swift`.
  timestamp: 2026-10-12T14:59:16.844848+00:00
- actor: claude-code
  id: 01m4ra6552yh02yteye0c6ngnx
  text: |-
    ### implement — changed
    - evidence: 3 files — IntegrationTests/Package.swift (adds swift-metrics 2.11.0 and the `MetricsTestKit` product), IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/CapturedSpans.swift (new shared `spans(named:in:)`; `onlySpan` and `children` use it), IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledModelIntegrationTests.swift (new test `twoCallsOpenAColdAndThenAWarmGenerateSpan`, `GenerateTelemetryOutcome`, `GenerateTelemetryExpectations`).
    - `swift test --package-path IntegrationTests --filter PooledModelIntegrationTests`: 6 tests passed. `swift test`: 1030 tests in 91 suites passed (11 known issues from before). The only warning is the mlx-swift "missing creator for mutated node" line of the dependency build.
    - TDD note: the production code is from ^bqn6m7k, thus the new test passed on its first run. The card asks for a test of the behavior that exists. No production code changed.
    - The test checks: two generate spans with cold flags [true, false], the model ref, guided=false; the load span is a child of the cold generate span; one time-to-first-token and one duration for each succeeded call, each time to first token > 0 and <= its duration; no leak of the prompt, the instructions (forbidden in the capture) or the answers (`context.leaks(forbidding:)` after the run); log records and metrics present.
    - next: /review
  timestamp: 2026-10-12T15:02:36.450380+00:00
depends_on:
- 01M4NY1MMSGG2YVBXYWBQN6M7K
position_column: doing
position_ordinal: '80'
title: 'Generate telemetry: integration test with the real LLM'
---
## What

Task `bqn6m7k` adds the generate span and the generate metrics, and tests them with `StubLanguageModel`. This task adds one integration test that runs the real LLM, so that the span, the cold and warm attribute and the time to first token are correct with a real model.

File: `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledModelIntegrationTests.swift`.

## Acceptance Criteria
- [x] One integration test runs the real LLM two times, and checks the `FoundationModelsExtras.generate` span, `generate.cold=true` on the first call and `generate.cold=false` on the second call, and a `FoundationModelsExtras.generate.time_to_first_token` value greater than 0.
- [x] The test also checks that no span, log record or metric carries the prompt or the output text, and that the capture saw at least one record.

## Tests
- [x] `swift test --package-path IntegrationTests --filter PooledModelIntegrationTests` passes.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature