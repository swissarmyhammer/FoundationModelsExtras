---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Tests: remove the clock reads, sleeps and time limits that stay in Tests/ and IntegrationTests/'
---
Found during ^k2k3b03. These places still read a clock, sleep, poll or set a time limit in a test. Each must end on the event that it expects, or on a failure event.

- IntegrationTests: `.timeLimit` on 8 suites (MLXModelLoader, PooledEmbedder, EvictionWait, ModelPool, PooledModel, ModelPoolSmoke, GenerationQueue, ToolHosting) and the comment in Support/RealModelSuites.swift.
- IntegrationTests: `Task.sleep` in ToolHostingFixtures.swift (3), EvictionWaitTests.swift, GenerationQueueIntegrationTests.swift, and the poll loop in Support/Waiting.swift.
- IntegrationTests: `ContinuousClock` reads in PooledEmbedderIntegrationTests, ModelPoolIntegrationTests, GenerationQueueIntegrationTests, ToolHostingIntegrationTests and Support/RecordingLoader.swift.
- Tests: `ContinuousClock` reads in SerialAsyncChainTests, GenerationQueueWorkerTests, BackgroundToolRunnerTests and ToolContextMountTests (elapsed time checks), and the `ContinuousClock()` default in Tests/MarketplaceFixtures/MarketplaceStoreFixture.swift.

Decide for each place if it is a wait (remove it) or a measure that a test asserts on (replace it with an event or a fake clock).