---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5b1wctxc7wwd13jjg74wsx2
  text: |-
    Research: HostingSeams.swift does not import FoundationModels, and `AgentLaunching: Tool` needs it. CatalogNoticeBoard.swift already imports it and holds `CatalogNoticing`, so the protocol went there, right after `CatalogNoticing`. No README, ARCHITECTURE.md or public-surface test lists the seam protocols, so nothing else needed an update.

    TDD: RED was the expected build failure (`cannot find type 'AgentLaunching' in scope`). GREEN was 3/3 for `swift test --filter AgentLaunching`. The full `swift test` passed every suite (1303 + 410 + 131 + 44 + 40 + 26 tests) with no failures. Its only warning was the known mlx-swift_Cmlx "missing creator for mutated node".

    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsExtras/Hosting/CatalogNoticeBoard.swift (protocol added), Tests/FoundationModelsExtrasTests/Hosting/AgentLaunchingTests.swift (new, 3 tests); full swift test green
    - next: /review; the push/send subtask stays open, to go together with the ToolCallWitness card
  timestamp: 2026-10-19T21:43:02.237378+00:00
- actor: claude-code
  id: 01m5b20cf70kd408s1qhvpghw7
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (9b8730a) — 0 findings, 0 confirmed, 0 refuted; 7 attempted, 0 failed; 2 files reviewed, 4 .kanban/ files excluded by .reviewignore; no prior Review Findings sections
    - next: orchestrator pushes to origin/main with the ToolCallWitness card and sends the sha to foundationmodelsrouter-75
  timestamp: 2026-10-19T21:45:12.935365+00:00
- actor: claude-code
  id: 01m5b20vh56cs51sdhxmf8cxaa
  text: |-
    ### finish iteration 1 — clean
    - implement: changed (2 files)
    - test: green (swift test: 1303 tests, 129 suites, only the known mlx metal warning)
    - commit: 9b8730a
    - review: clean (0 findings)
  timestamp: 2026-10-19T21:45:28.357270+00:00
position_column: done
position_ordinal: ffae80
title: 'AgentLaunching: a tool tells which catalog agents it can start now'
---
Request from foundationmodelsrouter-75, for the same hint as the ToolCallWitness card. Agents agreed to conform. The Router casts each original tool of a root session to AgentLaunching, and hints only when the list is not empty, naming an agent from the entries. Extras gives only the protocol, which is additive.

```swift
public protocol AgentLaunching: Tool {
    /// What this tool instance can start right now: the catalog entries filtered by its grant. An empty list means it can start nothing.
    func launchableAgents() async -> [CatalogEntry]
}
```

- [x] Add the protocol in Sources/FoundationModelsExtras/Hosting/HostingSeams.swift, next to the other seams (or next to CatalogNoticing in CatalogNoticeBoard.swift if that fits better). It uses the existing `CatalogEntry` (CatalogChangeNotice.swift). Doc comments in the style of the file: the hosts cast an `any Tool` to it, and an empty list means none.
- [x] Tests (Swift Testing, Tests/FoundationModelsExtrasTests/Hosting/AgentLaunchingTests.swift):
  - a conforming tool, held as `any Tool`, casts to `any AgentLaunching` and gives its entries in order;
  - a tool that does not conform fails the cast;
  - an empty list stays empty.
- [x] Full `swift test` is green with zero warnings, apart from the known Swift Build metal warning (^8pa1503).
- [x] After done, together with the ToolCallWitness card: push to origin/main, send the sha to foundationmodelsrouter-75, and the Router tells foundationmodelsagents-93. Pushed at a63ddda and sent to router-75 on 2026-10-19.