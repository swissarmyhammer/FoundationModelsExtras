---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5fcmbzc249hm3wptsycctpq
  text: |-
    Research:
    - `GraphQLAliasProbe` and `GraphQLEndpointConformance.problems` in Sources/FoundationModelsExtras/GraphQL/GraphQLTestKit.swift. Callers of `problems(of:scope:probe:...)`: GraphQLTestKitTests (3), GraphQLConventionTests (2). All use the single-probe form.
    - `GraphQLRun.subscribe` puts `rewritten.rewrites` into every subscription response, so `extensions.rewrites` is there on the first event.
    - `ChangeLog.changes(after: nil)` replays nothing, so ExampleGraph's `changes` never sends unless a change follows the subscribe. Plan: the probe passes `after: <cursor read before an append>`, so the buffered replay sends the first response at once and the test needs no timing.
    - The existing "subscription document that does not parse" check calls `iterator.next()` directly and would hang on a stream that stays open. The new first-response helper covers both sites.
    - To avoid hanging without a wall-clock timeout in tests: the wait races a sleep on an injected `RunClock` (Hosting/RunClock.swift, same module). Default is `ContinuousRunClock`. Tests use `ManualRunClock` and advance it, so no real time passes.
    - Alias for the root subscription field: `GraphQLAliasTable.byType["Subscription"]` (selection scope looks up `byType[type]`).
  timestamp: 2026-10-21T14:07:51.276752+00:00
- actor: claude-code
  id: 01m5fcx3k5jzpsa62z7zr742xf
  text: |-
    Implementation landed (TDD: RED was a compile failure on the missing `kind:` argument; GREEN 10/10 in GraphQLTestKitTests).
    - `GraphQLAliasProbe.Kind` (`.query` default, `.subscription`) plus `kind:` init parameter with a default, so existing calls are unchanged.
    - `GraphQLEndpointConformance.problems(of:scope:probes:codes:exceptions:clock:)` is new. The old `problems(of:scope:probe:codes:exceptions:)` forwards to it. GraphQLConventionTests still uses the single-probe form and compiles unchanged.
    - A subscription probe goes through `subscribe`. Its first response must carry the rewrite and no errors, the same `rewriteProblems` check the query probe uses. The wait races a sleep on an injected `RunClock` with a limit of `firstResponseLimit` (10 s). A stream that ends with nothing reports "gave no response"; a stream that stays open reports "gave no response within …". The existing "subscription document that does not parse" check now uses the same bounded wait. Before, it could hang on a stream that stays open.
    - ExampleGraph: `byType["Subscription"] = ["changes": ["noteChanges"]]` and `changesProbe(writing:)`. It reads the log cursor, appends one change, and probes with `after: cursor`, so the replay sends the first response at once. No timing is involved.
    - The tests use no wall-clock timeout. The "never sends" test uses `ManualRunClock` with `waitForSleepers` + `advance`.
    - Discovery: `AsyncThrowingStream { _ in }` (continuation dropped) stays open until cancelled. It is a handy stub for a silent subscription.
    - RunClock doc now names the conformance check as a reader.
  timestamp: 2026-10-21T14:12:37.605513+00:00
- actor: claude-code
  id: 01m5fcx68s7wwjpd3gk9wf12nj
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsExtras/GraphQL/GraphQLTestKit.swift, Sources/FoundationModelsExtras/Hosting/RunClock.swift, Tests/FoundationModelsExtrasTests/GraphQL/ExampleGraph.swift, Tests/FoundationModelsExtrasTests/GraphQL/GraphQLTestKitTests.swift; `swift test --filter GraphQLTestKitTests` 10/10 passed; `swift test` 1513 tests in 155 suites passed, exit 0, no compiler warnings (only the build-system MLX bundle "missing creator" note that the build already gave before this change)
    - next: /review
  timestamp: 2026-10-21T14:12:40.345837+00:00
position_column: doing
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
- [x] `ExampleGraph` probes a subscription alias (for example `noteChanges` → `changes`), and `problems` reports no problem.
- [x] A subscription alias the endpoint doesn't rewrite gives a problem that names the probe.
- [x] Existing callers of `problems(of:scope:probe:...)` compile with no change.

#graphql