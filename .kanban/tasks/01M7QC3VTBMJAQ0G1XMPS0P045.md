---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qccpypb5s2xa1n4xg18r9k
  text: |-
    Research:
    - The worktree branch had an extra commit 1c69b4f (model-pool) that is not on main. A fast-forward to 5b0d5e5 was not possible. The branch was reset to 5b0d5e5 (main). The commit 1c69b4f stays on other worktree branches.
    - `sendToAgent` in InMemorySessionDirectoryState+Messages.swift calls `newestLiveRoot(agentID:in:)`. The `.folder` address also calls `newestLiveRoot` with agentID nil. Thus `newestLiveRoot` stays; its agentID parameter becomes unused and is removed.
    - Sibling tests that expect the old rule (not changed here): FoundationModelsMultitool/Tests/FoundationModelsMultitoolTests/SessionsToolMessageTests.swift:208 ("send message to @agent reaches the live root session of the agent in the folder of the caller") and :225 ("send message to @agent:/path reaches the live root session of the agent in that folder"). Both use InMemorySessionDirectory() with no launcher, so under the new rule the send throws noLauncher.
    - FoundationModelsRouter tests use RouterSessionDirectory, not InMemorySessionDirectory.
  timestamp: 2026-11-18T13:08:59.478335+00:00
position_column: doing
position_ordinal: '8480'
title: 'InMemorySessionDirectory: an agent address starts a new root session'
---
## Current behavior
- The doc of `SessionAddress.agent` now says that the directory starts a new root session of the agent for each send.
- `InMemorySessionDirectory` (`Sessions/InMemorySessionDirectoryState+Messages.swift`, `deliverToAgent` and `newestLiveRoot`) still delivers to the newest live root session of the agent, and starts a session only when there is none.
- The test "an agent address gives the newest live root session of the agent in the folder" in `InMemorySessionDirectoryDeliveryTests.swift` expects the old rule.

## Work
- Make the in-memory directory start a new root session (origin `.message`) for each `.agent` address, so that it agrees with the documented contract.
- Change the old test to expect the new rule.

## Tests (Swift Testing)
- [ ] A second send to the same `.agent` address starts a second root session.

#at-sessions