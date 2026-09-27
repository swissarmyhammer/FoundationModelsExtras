---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3gc99vv5r4s85hhsvghm6y6
  text: |-
    Implementation landed.
    - `ToolCallReport.init?(closing:attachments:)` is now `public`. Its doc comment tells how a host uses it.
    - `RunPlane.wait(completionToken:seconds:)` is now `public`.
    - `RunPlane.StartResult`, `RunPlane.start(...)` and `RunPlane.updateProgress(...)` are now `@_spi(Testing) public`. Each doc comment names the normal path (ToolMounting, ToolContext) and the SPI import.
    - New test files: `Tests/FoundationModelsExtrasTests/Hosting/ToolCallReportAndWaitPublicSurfaceTests.swift` (plain import, 3 tests) and `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestingSPIPublicSurfaceTests.swift` (`@_spi(Testing) import`, no `@testable`, 2 tests).
    - RED was confirmed before each change: the plain file failed with "extra argument 'closing'" and "'wait' is inaccessible due to 'internal' protection level"; the SPI file failed with "'StartResult' / 'start' / 'updateProgress' is inaccessible due to 'internal' protection level". A `@testable` import in other files of the target does not make these internal members visible in a file with a plain import.
    - Discovery: `@testable import` does NOT open an `@_spi` member. After the change, four test files that call `start` or `updateProgress` failed with "'start' is inaccessible due to '@_spi' protection level". Their import is now `@_spi(Testing) @testable import FoundationModelsExtras`: RunPlaneTests.swift, RunPlaneActorTests.swift, RunPlaneTestSupport.swift, ToolContextTests.swift. A router or multitool test file with `@testable` that calls these members also needs `@_spi(Testing)` on its import.
    - No production caller changed: `BackgroundToolRunner` (start) and `ToolRun` (updateProgress) are in the same module.
  timestamp: 2026-09-27T02:49:39.451852+00:00
- actor: claude-code
  id: 01m3gc9erfj9qz77w7rg71s5cg
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsExtras/Hosting/ToolCallReport.swift, Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallReportAndWaitPublicSurfaceTests.swift (new), Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestingSPIPublicSurfaceTests.swift (new), and the import line of RunPlaneTests.swift, RunPlaneActorTests.swift, RunPlaneTestSupport.swift, ToolContextTests.swift. `swift build`: 0 warnings, 0 errors. `swift test`: exit 0, 1350 Swift Testing tests pass (725 + 396 + 125 + 44 + 34 + 26), 0 failures.
    - next: review
  timestamp: 2026-09-27T02:49:44.463198+00:00
- actor: claude-code
  id: 01m3gcdd3prq4pqx1dfmxcp5xe
  text: |-
    ### commit — changed
    - evidence: swift build (0 warnings); swift test (725 tests, 0 failures); commit 11404f3 "feat(hosting): open the run-plane and report inits to SPI tests"
    - next: none
  timestamp: 2026-09-27T02:51:53.846787+00:00
- actor: claude-code
  id: 01m3gcm6vmn4gqsant97mexbrj
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (11404f3); 0 findings, 0 confirmed, 0 refuted; 7 attempted, 0 failed; 8 files reviewed; 2 .kanban files excluded by .reviewignore.
    - next: none. Task moved to done.
  timestamp: 2026-09-27T02:55:36.820574+00:00
- actor: claude-code
  id: 01m3gcmed240bezsczws0bp0qh
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 source files (access levels), 2 new public-surface test files, 4 test import lines
    - test: green — swift test, 725 passed in FoundationModelsExtrasTests, 0 warnings (run by the commit step)
    - commit: 11404f3
    - review: clean — task is done. The router pins 11404f3 (replaces fa43d18).
  timestamp: 2026-09-27T02:55:44.546391+00:00
depends_on:
- 01M3FPA83C04HNESZYBEBTPRDG
position_column: done
position_ordinal: c280
title: 'Tool hosting 5: make ToolCallReport.init, RunPlane.wait public, and RunPlane.start and updateProgress SPI for tests'
---
## Why
The router session checked the new Extras API against the router code outside `Hosting/`. Two gaps break the router:
1. The router `OperationEventJournal.postToolCallReport(closing:attachments:)` (Session/OperationEventJournal.swift:96-97) makes a `ToolCallReport` with `init?(closing:attachments:)`. That code stays in the router, and `ToolInvocationLivenessTests.swift:741-790` tests it. The initializer is internal in Extras.
2. Router tests that need a `RoutedSession` (`RespondRunPlaneDrainTests.swift`, `BackgroundRunTranscriptTests.swift`) and the multitool tests start runs, update progress and wait on the run plane directly. In Extras these are internal.

## What to do
- [x] Make `ToolCallReport.init?(closing:attachments:)` public, with a doc comment. `ToolCallSpan` and `postToolCallReport` stay internal.
- [x] Make `RunPlane.wait(completionToken:seconds:)` public. `ToolContext.wait` already gives the same operation to tools.
- [x] Make `RunPlane.start(tool:op:kind:completionToken:canceler:body:)`, its result type `StartResult`, and `RunPlane.updateProgress(completionToken:detail:)` `@_spi(Testing) public`. A normal user does not see them. A test uses `@_spi(Testing) import FoundationModelsExtras`. Note: Extras has no `track(... settling:)`; `start(... body:)` replaces it, and the body returns the terminal event.
- [x] Public-surface tests: one test with a plain `import FoundationModelsExtras` for `ToolCallReport.init?(closing:attachments:)` and `RunPlane.wait`; one test with `@_spi(Testing) import FoundationModelsExtras` (no `@testable`) that calls `start`, `updateProgress` and `wait`.
- Keep it small. No other API change.

## Acceptance criteria
- [x] `swift build` 0 warnings; `swift test` all pass.
- [x] The public-surface tests compile only with the access levels above.

#tool-hosting #cross-repo