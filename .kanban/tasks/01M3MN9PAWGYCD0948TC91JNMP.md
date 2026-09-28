---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mte6d56hspq6yns22ykdfz
  text: |-
    Implement notes:
    - ExtrasTelemetry.swift now holds SpanName.tool ("FoundationModelsExtras.tool"), AttributeKey (4 keys, moved from ToolCallSpan), MetricName, LogMetadataKey (trace.id, span.id from task C, plus tool.name and session.id), EnterRecord.message, makeLogger, the counter and timer factories and a new recordToolCall(toolName:outcome:duration:).
    - ToolCallSpan.withSpan now calls TracedCall.run, with a logger made at call time. The body gets a ToolCallSpan.Call (span, tool name, start instant). record(outcome:on:) writes the outcome and records one count and one duration.
    - Decision: the metrics keep the dimensions tool.name and tool.outcome only. No tool.run_kind dimension: the span keeps it, and a dimension would split the count of one tool into two series. For a background call the duration measures the start only, as the span does (documented in ToolCallSpan and CHANGELOG).
    - The FoundationModelsExtrasTests target now depends on MetricsTestKit, to read counter values and timer values from the capture factory.
    - The os scan test is in TelemetryDependencyTests, which already reads Sources/ through FixtureFile. The two scan tests share one helper.
    - Router package not changed.
  timestamp: 2026-09-28T20:13:57.541915+00:00
- actor: claude-code
  id: 01m3mte8w7f4598q2db1nkb48e
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Telemetry/TracedCall.swift, Hosting/ToolCallSpan.swift, Hosting/RunToCompletionRunner.swift, Hosting/BackgroundToolRunner.swift, Hosting/ContextBindingTool.swift, Package.swift, CHANGELOG.md, Tests/.../Hosting/ToolCallSpanTests.swift, Tests/.../Telemetry/ExtrasContentSafetyTests.swift (new), ExtrasTelemetryTests.swift, TracedCallTests.swift, TelemetryDependencyTests.swift. Focused run: 26 tests in 5 suites passed.
    - next: test
  timestamp: 2026-09-28T20:14:00.071628+00:00
- actor: claude-code
  id: 01m3mth9qvgw6vztmvss7j3cht
  text: |-
    ### test — green
    - evidence: swift test --parallel — Swift Testing runs: 131, 40, 44, 26 and 774 tests passed, 0 failed, 0 skipped. The 4 known issues are the withKnownIssue checks of TelemetryCaptureTests (task B), not new. No compiler warnings. The only other warnings are the SwiftPM "disk I/O error" manifest cache lines of the environment. Filter run before: FoundationModelsExtrasTests.(ToolCallSpanTests|ExtrasContentSafetyTests|ExtrasTelemetryTests|TracedCallTests|TelemetryDependencyTests) — 26 tests passed.
    - next: commit
  timestamp: 2026-09-28T20:15:39.259433+00:00
- actor: claude-code
  id: 01m3mttqntd7br6yvde4sn66am
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (927033f) — 0 findings, 0 confirmed, 0 refuted; 12 files reviewed, 7 validator runs attempted, 0 failed. Skipped: .kanban files (ignore rule) and CHANGELOG.md (no validator).
    - next: done

    ### finish iteration 1 — clean
    - commit: 927033f feat(telemetry): put the tool span names in ExtrasTelemetry, rename the span to FoundationModelsExtras.tool, and record the tool-call metrics
    - test: swift test --parallel green (131 + 40 + 44 + 26 + 774 tests passed, 0 failed)
    - review: clean, task moved to done
  timestamp: 2026-09-28T20:20:48.442252+00:00
depends_on:
- 01M3MN838VZ4QX57C3965XMGKV
- 01M3MN8N9P4RPET2V5JZ6JQD9G
- 01M3MN91YK71YVJ9C7WYKGZ2AA
position_column: done
position_ordinal: d580
title: 'OTel D: add the ExtrasTelemetry vocabulary file for the tool span and the tool-call metrics'
---
## What

Part D of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 3: each package has one vocabulary file, like `FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift`, with the span names, attribute keys, metric names and log metadata keys, and the module name as the prefix.

Current state (checked 2026-09-28):
- `/Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift` holds the span name `"FoundationModelsRouter.tool"` and the attribute keys `tool.name`, `session.id`, `tool.run_kind`, `tool.outcome`, in `ToolCallSpan.AttributeKey`. `ToolCallSpan.withSpan` is called from `RunToCompletionRunner.swift:35`, `BackgroundToolRunner.swift:36` and `ContextBindingTool.swift:38` in the same folder. `ToolCallSpan.record(outcome:on:)` writes the outcome.
- No file in Extras uses `os.Logger` or `OSSignposter`. Thus the "replace os.Logger" part of the request is empty for Extras. Keep a test that proves it (below).

Work:
- [x] Add `Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift`: one `enum ExtrasTelemetry` with nested enums `SpanName`, `AttributeKey`, `MetricName`, `LogMetadataKey`, and the log label of the module. Move the span name and the four attribute keys from `ToolCallSpan` into it; `ToolCallSpan` uses the vocabulary. Move the constants of task C (`TracedCall`) into it too.
- [x] Rename the tool span from `FoundationModelsRouter.tool` to `FoundationModelsExtras.tool` (decided: the user approved the rename on 2026-09-28, relayed by the swissarmyhammer-05 session). Put the new name in `ExtrasTelemetry.swift`. The Extras sites are `Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift:13` and `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift:32`. Do not change the Router: a separate Router task changes `RoutedLLM.swift:250`, `Tracing/RouterTracing.swift:40` and `ToolTracingTests.swift:31`, and that task depends on this task.
- [x] Tool-call metrics with swift-metrics: a `Counter` `FoundationModelsExtras.tool.calls` and a `Timer` `FoundationModelsExtras.tool.duration`, both with the dimensions `tool.name` and `tool.outcome` only. Record them in the place where `ToolCallSpan.record(outcome:on:)` records the outcome, so that each outcome gives one count and one duration. For a background run, decide if the duration measures the start or the full run, to match `ToolRunKind`, and document it. Add `tool.run_kind` as a dimension only if you decide that it is necessary.
- [x] Use `TracedCall` of task C for the tool span, so that each tool call also writes one "enter" log record (tool calls can suspend for a long time).
- [x] No content (rule 4): no tool arguments or tool output in any attribute, log record or metric dimension.

## Acceptance Criteria
- [x] All span names, attribute keys, metric names and log metadata keys of the core target are in `ExtrasTelemetry.swift`, and `ToolCallSpan.swift` has no string literal for them.
- [x] Each tool call through the three runners gives one span, one "enter" log record, one count and one duration with the dimensions `tool.name` and `tool.outcome`.
- [x] The tool span name is `FoundationModelsExtras.tool`, from `ExtrasTelemetry`, and no source or test file in Extras contains `FoundationModelsRouter.tool`.
- [x] No source file in the package imports `os` for logging or uses `OSSignposter`.

## Tests
- [x] Update `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift` to read the name and keys from `ExtrasTelemetry`, and add metric checks with the `TelemetryTestSupport` capture of task B: one count and one duration for each outcome (success, failure, and a background start).
- [x] Add a content-safety test in `Tests/FoundationModelsExtrasTests/Telemetry/ExtrasContentSafetyTests.swift` that runs a tool call through each of the three runners with a distinctive argument and output, and uses the task B helper with those strings as forbidden.
- [x] Add a test that scans `Sources/` (through `PackageRootValidation.packageRoot()` in `Tests/FoundationModelsExtrasTests/PackageRootValidation.swift`) and fails on `os.Logger`, `import os.log`, `Logger(subsystem:` or `OSSignposter`. (Done in `TelemetryDependencyTests`, through `FixtureFile.packageRoot`, because `PackageRootValidation.packageRoot()` does not work from a test subfolder.)
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.