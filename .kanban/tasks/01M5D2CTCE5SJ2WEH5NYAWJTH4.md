---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d5fgy0menexahnbzv2bc0h
  text: 'Research: generate telemetry tests live in Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift, reading via GenerateTelemetryExpectations in ModelPoolTestSupport.swift. The fake model is StubLanguageModel.swift: it sends one updateUsage (input 0/0, output N) only on answer rounds, never on the tool-call round, so a multi-round usage test needs the stub to give per-call usage (including the tool round). SDK: Usage.Input {totalTokenCount: Int, cachedTokenCount: Int} are non-optional, so a round with a usage always carries all three counts; "only record when reported" = when some round gave a usage. Span int attributes read back as .int64. Plan: GenerateTelemetry.TokenCounts struct (input/cached/output) replacing outputTokenCount(in:); Rounds keeps per-round usage, the summed usage and the first round''s usage; record() adds generate.input_tokens / generate.cached_tokens counters and four span attributes (summed + first-round input/cached).'
  timestamp: 2026-10-20T17:24:23.616568+00:00
- actor: claude-code
  id: 01m5d5rne4qp0qz4pd1khywya8
  text: |-
    Implementation landed (TDD). RED: the two new token tests failed with `.missingMetric(label: "FoundationModelsExtras.generate.input_tokens", ...)` (the name constants were added first so the tests compiled). GREEN: all three target tests pass; full `swift test` ran once: 1380 tests in 135 suites, 0 failures.

    What changed:
    - GenerateTelemetry.swift: `outputTokenCount(in:)` became `tokenCounts(in:) -> GenerateTokenCounts?` (input, cached, output). `Rounds` keeps the per-round counts, the summed counts, and the first round's counts (`endRound(after:)` is now a mutating method on `Rounds`). `record(outcome:)` adds the input/cached counters and puts the summed and the first-round input/cached counts on the span. The doc comment says that the summed input counts the context once per round.
    - ExtrasTelemetry.swift: MetricName.generateInputTokens / generateCachedTokens; AttributeKey generate.input_tokens, generate.cached_tokens, generate.first_round.input_tokens, generate.first_round.cached_tokens.
    - Test stub: `StubLanguageModelScript(outputTokenCount:)` became `usages: [StubTokenUsage]`, one per generation call. The usage is now also sent on the tool-call round, so the multi-round test has different counts in each round (tool round 40/10, answer round 55/40; sums 95/50).

    Not done here: the acceptance item "Pushed to main, and the sha sent to foundationmodelsacpagent-a5" belongs to the commit step, because this step was told not to commit.
    Build note: the only build warning is the SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle" line. It comes from a dependency's resource bundle, not from this change.
  timestamp: 2026-10-20T17:29:23.140592+00:00
- actor: claude-code
  id: 01m5d5rr7x48edsrf1ct6mykjt
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/Telemetry/GenerateTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Tests/FoundationModelsExtrasTests/ModelPool/StubLanguageModel.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift; `swift test`: 1380 tests / 135 suites passed, 0 failures
    - next: /review; then commit, push to main and send the sha to foundationmodelsacpagent-a5 (the last acceptance item)
  timestamp: 2026-10-20T17:29:26.013778+00:00
position_column: doing
position_ordinal: '80'
title: Record input and cached token counts in generate telemetry
---
## What

`FoundationModelsExtras.generate.*` records time_to_first_token, duration, output_tokens and tokens_per_second, but nothing about the prompt side. `GenerateTelemetry.outputTokenCount(in:)` (`Sources/FoundationModelsExtras/Telemetry/GenerateTelemetry.swift:88-90`) reads only `usage(...)?.output.totalTokenCount` from the `Usage` value it finds with the Mirror walk.

The same `Usage` value also has `input.totalTokenCount` and `input.cachedTokenCount`. mlx-swift-lm `stable` (1eb84ff) fills both: `Libraries/MLXFoundationModels/MLXLanguageModel.swift:592-599`. `cachedTokenCount` is the prefix that the prompt cache reused.

## Why

The FoundationModelsACPAgent session is working out why SWE-bench runs are slow, and it can't separate prefill cost from decode cost. The transcripts show the whole context going in on every call, but a timing fit says prompt tokens cost almost nothing, which points to cache hits. If input and cached counts sit next to TTFT, the prefill rate is just (input − cached) / TTFT.

## Approach

- Change the usage reader so it returns output, input and cached counts. Generalize `outputTokenCount(in:)`, for example into a small struct holding all three counts.
- `GenerateCall.Rounds` tracks each round's last `updateUsage` input and cached counts the same way it tracks `roundOutputTokens` (a later usage in the same round replaces the earlier one), and `endRound` adds them to the call totals. It also keeps the first round's input and cached counts.
- In `record(outcome:)`:
  - `Metrics.Counter` `generate.input_tokens` from the summed input.totalTokenCount, with the same dimensions as the other generate metrics (model ref). Add the name to `ExtrasTelemetry.MetricName`.
  - `Metrics.Counter` `generate.cached_tokens` from the summed input.cachedTokenCount, with the same dimensions.
  - Put both totals on the `FoundationModelsExtras.generate` span as attributes. Add the keys to `ExtrasTelemetry.AttributeKey`.
  - **Required:** also put the first round's input and cached counts on the span as separate attributes. TTFT covers only the first round, so (first-round input − first-round cached) / TTFT is the exact prefill rate. The ACPAgent session confirmed it needs this: its tool-heavy runs have many rounds, so the summed count alone gives a wrong prefill rate.
- Only record a metric or attribute when some round reported that count, the same rule as output tokens today.
- A call with tool calls has several rounds, and each round sends the whole context again. Summing input across rounds therefore counts what was fed in total. Write this down in the doc comment.

## Constraints

- Content-safety rule: record counts only, never prompt or transcript text.
- Write the failing test first. Extend the existing generate telemetry tests so that a fake model emits an `updateUsage` with input/cached counts, then assert the counters and span attributes. Include a multi-round case that checks the totals and first-round attributes separately.

## Acceptance

- [x] Failing test first, then green
- [x] `generate.input_tokens` and `generate.cached_tokens` counters, model-ref dimension
- [x] Summed input/cached counts as attributes on the generate span
- [x] First-round input/cached counts as separate attributes on the generate span
- [x] No content recorded
- [ ] Pushed to main, and the sha sent to the FoundationModelsACPAgent session (foundationmodelsacpagent-a5), which asked for it

Requested by the FoundationModelsACPAgent session. The Router session (foundationmodelsrouter-08) has a matching ask for its transcript/metrics side.