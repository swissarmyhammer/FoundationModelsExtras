---
assignees:
- claude-code
depends_on:
- 01M4NY1MMSGG2YVBXYWBQN6M7K
position_column: todo
position_ordinal: '9280'
title: 'Generate telemetry: integration test with the real LLM'
---
## What

Task `bqn6m7k` adds the generate span and the generate metrics, and tests them with `StubLanguageModel`. This task adds one integration test that runs the real LLM, so that the span, the cold and warm attribute and the time to first token are correct with a real model.

File: `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledModelIntegrationTests.swift`.

## Acceptance Criteria
- [ ] One integration test runs the real LLM two times, and checks the `FoundationModelsExtras.generate` span, `generate.cold=true` on the first call and `generate.cold=false` on the second call, and a `FoundationModelsExtras.generate.time_to_first_token` value greater than 0.
- [ ] The test also checks that no span, log record or metric carries the prompt or the output text, and that the capture saw at least one record.

## Tests
- [ ] `swift test --package-path IntegrationTests --filter PooledModelIntegrationTests` passes.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature