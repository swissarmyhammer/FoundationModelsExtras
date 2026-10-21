---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'GraphQLEndpointConformance: subscription alias probes through subscribe'
---
Requested by the Multitool coordinator. The agents session found the gap after EXTRAS-11. Low priority; nothing is blocked on it.

`GraphQLEndpointConformance.problems` runs `GraphQLAliasProbe` through `execute` (Sources/FoundationModelsExtras/GraphQL/GraphQLTestKit.swift, around line 243). So the probe can't check a subscription alias, for example `agentChanges`, `skillChanges`, `sessionChanges` or `kanbanChanges`. Rule 9 of EXTRAS-9 gives every endpoint one of these aliases. Skills and Agents test theirs by hand through `subscribe`.

## Work
- Let a probe say it is a subscription. For example, add a kind to `GraphQLAliasProbe` (`.query` by default, or `.subscription`), or add a separate subscription probe. Keep the existing calls source compatible.
- For a subscription probe, call `endpoint.subscribe(...)`, take the first response, and check that `extensions.rewrites` holds the rewrite from `from` to `to` and that the response has no error. If no first response arrives, report a problem; don't hang. A test endpoint can make its `changes` send at once, for example by appending to the ChangeLog before or after it subscribes.
- Let `problems` take more than one probe, so an endpoint can probe a query alias and a subscription alias in one call. Keep the single-probe form.

## Acceptance criteria
- [ ] `ExampleGraph` probes a subscription alias (for example `noteChanges` → `changes`), and `problems` reports no problem.
- [ ] A subscription alias the endpoint doesn't rewrite gives a problem that names the probe.
- [ ] Existing callers of `problems(of:scope:probe:...)` compile with no change.

#graphql