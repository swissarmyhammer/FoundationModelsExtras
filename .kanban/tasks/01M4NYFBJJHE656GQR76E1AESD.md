---
assignees:
- claude-code
depends_on:
- 01M4NY0Z31YN498MYBJPMDD5EZ
position_column: todo
position_ordinal: '9180'
title: 'Embed telemetry: integration test with the real embedding model'
---
## What

Task `pmdd5ez` adds the embed span tree and the embed metrics, and tests them with no model. This task adds one integration test that uses the real embedding model, so that the span tree and its attributes are correct with real tokens and real sub-batches.

File: `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift`.

## Acceptance Criteria
- [ ] One integration test embeds texts of mixed length with the real model, and checks the `FoundationModelsExtras.embed` span, its `FoundationModelsExtras.embed.tokenize` child span, one `FoundationModelsExtras.embed.sub_batch` child span for each sub-batch, and their attributes.
- [ ] The test also checks that no span, log record or metric carries an input text, and that the capture saw at least one record.

## Tests
- [ ] `swift test --package-path IntegrationTests --filter PooledEmbedderIntegrationTests` passes.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature