---
assignees:
- claude-code
depends_on:
- 01M4NYEXT1DNXTGVYE10248SQN
position_column: todo
position_ordinal: 8f80
title: 'Tool-call telemetry: the duration timer and the span of ContextBindingTool measure the same interval'
---
## What

The timer and the span measure different intervals. In `ContextBindingTool.call(arguments:)` (`Sources/FoundationModelsExtras/Hosting/ContextBindingTool.swift:37`), `ToolCallSpan.record(outcome:on:)` (`:42`) stops the duration before `postToolCallReport` (`:43`), but the span includes the report.

Change: make the timer and the span measure the same interval. Record the outcome and the duration after the report, or end the span at the same point. Update each doc comment that states the interval.

This task was part (d) of task `vsvb1hx`.

## Acceptance Criteria
- [ ] In `ContextBindingTool`, the recorded duration covers the same interval as the span, with the report included.
- [ ] Each call still records exactly one count and one duration.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift`: with `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, a `ContextBindingTool` call whose report is slow records a duration that includes the report time, and the span covers the same interval.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug