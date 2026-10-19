---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'AgentLaunching: a tool tells which catalog agents it can start now'
---
Request from foundationmodelsrouter-75, for the same hint as the ToolCallWitness card. Agents agreed to conform. The Router casts each original tool of a root session to AgentLaunching, and hints only when the list is not empty, naming an agent from the entries. Extras gives only the protocol, which is additive.

```swift
public protocol AgentLaunching: Tool {
    /// What this tool instance can start right now: the catalog entries filtered by its grant. An empty list means it can start nothing.
    func launchableAgents() async -> [CatalogEntry]
}
```

- [ ] Add the protocol in Sources/FoundationModelsExtras/Hosting/HostingSeams.swift, next to the other seams (or next to CatalogNoticing in CatalogNoticeBoard.swift if that fits better). It uses the existing `CatalogEntry` (CatalogChangeNotice.swift). Doc comments in the style of the file: the hosts cast an `any Tool` to it, and an empty list means none.
- [ ] Tests (Swift Testing, Tests/FoundationModelsExtrasTests/Hosting/AgentLaunchingTests.swift):
  - a conforming tool, held as `any Tool`, casts to `any AgentLaunching` and gives its entries in order;
  - a tool that does not conform fails the cast;
  - an empty list stays empty.
- [ ] Full `swift test` is green with zero warnings, apart from the known Swift Build metal warning (^8pa1503).
- [ ] After done, together with the ToolCallWitness card: push to origin/main, send the sha to foundationmodelsrouter-75, and the Router tells foundationmodelsagents-93.