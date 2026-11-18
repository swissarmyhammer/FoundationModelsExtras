---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qgtm8v6t9571mf3vvw0mjt
  text: |-
    Research done.
    - `ResolverWarnings` (GraphQL/ResponseWarnings.swift) is the pattern: `@TaskLocal static var current`, `Mutex` list, no-repeat add. The run binds it in the private `result(of:operationName:context:)` in GraphQLRun.swift.
    - `respond` gives `GraphQLResponse` only `rewritten.rewrites` today. `answerParseFailure` gives no rewrites at all. `result(of:)` throws a `GraphQLError` only when the rewritten text does not parse, before a resolver runs.
    - `subscribe` encodes each event with `rewritten.rewrites` only. It keeps that.
    - `ExampleGraph` is used by many tests (SDL, conformance probes). The new tests use a small schema of their own in a new test file, so the existing schema stays the same.
    - `NameRewrite` is `Hashable`, so the no-repeat test of `add` compares full items.
  timestamp: 2026-11-18T14:26:29.787672+00:00
- actor: claude-code
  id: 01m7qh0r6nys5z4y2x4pxw9zgm
  text: |-
    Implementation landed.
    - New `ResolverRewrites` (task local, `Mutex<[NameRewrite]>`, add with no repeat by full `NameRewrite` equality).
    - `respond` makes one collector for each call and binds it with `ResolverRewrites.$current.withValue` around the private `result(of:)`, so it is in effect together with `ResolverWarnings.collecting`. The response gives `rewritten.rewrites + collector.list`. `answerParseFailure` gives `collector.list`: it is empty before the run, and it keeps the resolver rewrites for a failure after the run. The name rewrites of a parse failure stay absent, as before.
    - `subscribe` is not changed; its doc tells that a subscription response has only the name rewrites.
    - Docs updated: `respond`, `subscribe`, `GraphQLResponse` (type, `rewrites`, init parameter, key), `NameRewrite` (type, members, init).
    - Tests use their own small schema (`RewriteAPI`) in ResolverRewritesTests.swift, so `ExampleGraph` and its SDL do not change. RED: 5 of 7 failed for the expected reason (no binding); GREEN: 7 of 7.
    - Formatting: temporary swift-format configuration (4 spaces, lineLength 120). Only the new test file changed (import order). Other diffs that the formatter shows are on lines this task did not change, so they stay.
  timestamp: 2026-11-18T14:29:50.421862+00:00
- actor: claude-code
  id: 01m7qh0v044cddzng4gdekv9hg
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/GraphQL/ResolverRewrites.swift (new), Sources/FoundationModelsExtras/GraphQL/GraphQLRun.swift, Sources/FoundationModelsExtras/GraphQL/GraphQLResponse.swift, Sources/FoundationModelsExtras/GraphQL/NameRewrite.swift, Tests/FoundationModelsExtrasTests/GraphQL/ResolverRewritesTests.swift (new, 7 tests). `swift test --filter FoundationModelsExtrasTests`: 2032 tests in 194 suites passed, no warnings in the changed files.
    - next: /review
  timestamp: 2026-11-18T14:29:53.284230+00:00
position_column: doing
position_ordinal: '80'
title: A resolver can add a rewrite report to extensions.rewrites
---
Request from FoundationModelsMultitool (its task ^gxqmxj6). The `sendMessage` mutation of the sessions endpoint must report an address alias in `extensions.rewrites`. Examples: `@agent:/path` reads as `@agent` with the lookup folder `/path`. A folder path alone names the newest root session in that folder. The tool answer already shows this, but the GraphQL endpoint cannot.

## Current behavior
- `GraphQLResponse` (`Sources/FoundationModelsExtras/GraphQL/GraphQLResponse.swift`) takes `rewrites` only from `RewrittenDocument.rewrites`, which is the name rewrite of the document.
- `GraphQLResponse` removes a `rewrites` key from `responseExtensions()` (`ownedKeys`).
- `API.result(of:operationName:context:)` in `GraphQL/GraphQLRun.swift` is private.
- `GraphQLRunContext` has conforming types in Kanban, Agents, Skills, ACPAgent and Multitool. A new protocol requirement with no default breaks all of them.

## Work
1. Add `public final class ResolverRewrites: Sendable` to the `GraphQL` folder. Use the same pattern as `ResolverWarnings` in `ResponseWarnings.swift`:
   - `@TaskLocal public static var current: ResolverRewrites?`
   - a `Mutex<[NameRewrite]>`
   - `public func add(_ rewrite: NameRewrite)`, which does not add an item that is the same as an item already in the list
   - `public var list: [NameRewrite]`
   A synchronous resolver and an async resolver can both call `ResolverRewrites.current?.add(...)`, because child tasks read the task local of their parent.
2. In `API.respond(to:...)`, bind a new collector during the run, together with the existing `ResolverWarnings.collecting`. Then give `GraphQLResponse` the list `rewritten.rewrites + collector.list`: first the name rewrites, then the resolver rewrites in the order of the adds. Keep the resolver rewrites when the run gives GraphQL errors (`answerParseFailure` after the run). A document that does not parse has no resolver rewrites.
3. Subscriptions: a response of a subscription keeps only the name rewrites. Write this in the doc.
4. Update the docs of `respond`, `GraphQLResponse.rewrites` and `NameRewrite`. An item of `extensions.rewrites` can come from the name rewrite or from a resolver that read a value in a different form. For a resolver item, `from` is the text the caller wrote, `to` is the canonical form, and `path` is the path of the value (for example `["sendMessage", "input", "to"]`).
5. Do not change the `GraphQLRunContext` protocol. Do not change `GraphQLResponse.init`, except to add things.

## Tests (Swift Testing), in Tests/FoundationModelsExtrasTests/GraphQL/
- [x] A resolver that adds one rewrite: the response has it in `extensions.rewrites`.
- [x] The document also has a name rewrite: the name rewrite comes first, then the resolver rewrite.
- [x] Two adds of the same rewrite give one item.
- [x] A resolver in a child task (an async field of a list) adds a rewrite, and the response has it.
- [x] A run with no rewrite has no `extensions.rewrites` key, as before.
- [x] An add with no bound collector does nothing (no crash).
- [x] Two runs at the same time do not mix their rewrites.

## Acceptance
- All tests pass. No conforming type in another package has to change.
- When this is on origin/main, send the sha to foundationmodelsmultitool-89 (task ^gxqmxj6). #at-sessions