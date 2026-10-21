---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f40dh8wj6emskc7n8r05g4
  text: |-
    Research:
    - `GraphQLEndpointConformance.problems(of:scope:probe:)` lives in GraphQLTestKit.swift; callers: GraphQLTestKitTests (3 calls) and FoundationModelsACPAgent SettingsGraphTests (expects `problems.isEmpty`). SettingsGraph has no `changes`/`cursor` yet (ACPA-17), so once the new rules apply by default that test reports rule 9 (and rule 7 for its mutations) until ACPA-17 adds exceptions or conforms; the call itself stays source compatible.
    - `ExampleGraph` (test fixture) fails rule 7 (`deleteNote(id:)`) and rule 9 (no `changes`, no `cursor`), so `exampleEndpointConforms` would break. Plan: make ExampleGraph obey the rules (ChangeLog-backed `cursor` + `changes(after:)` with `NoteChange`, `deleteNote` -> `removeNote(input: RemoveNoteInput!)`), and update the one NameRewriteTests call that sent `deleteNote`. Its root container `shelf` breaks rule 5, which the check does not read.
    - GraphQL SDL reading: `buildSchema(source:)`, `object.fields()` -> OrderedDictionary<String, GraphQLField>, `GraphQLField.args` -> OrderedDictionary<String, GraphQLArgument>, `type.debugDescription` gives SDL form (`String!`, `[ID!]!`), `is GraphQLNonNull` tells required.
    - Rule 8 design: the check cannot find the codes of an endpoint from the SDL or one call, so the endpoint passes them as `codes: [String] = []` to `problems`.
  timestamp: 2026-10-21T11:37:08.904472+00:00
- actor: claude-code
  id: 01m5f4hh1b33cyg7rwab9vrfz4
  text: |-
    Implementation landed (not committed):
    - New Sources/FoundationModelsExtras/GraphQL/GraphQLConventions.swift: public `GraphQLConventionRule` (scope=3, mutations=7, codes=8, changes=9; `name` gives "rule N"), public `GraphQLConventionException(rule:removedBy:)`, internal `GraphQLConventions` with one check per rule (rule 3 is a name->scope table; names the rule does not list pass).
    - `GraphQLEndpointConformance.problems(of:scope:probe:codes:exceptions:)`: `codes` and `exceptions` default to `[]`, so existing calls compile unchanged. Each convention problem starts with "rule N: ". An exception that names no task (empty/white space `removedBy`) is itself a problem.
    - Rule 8 choice: the endpoint passes its codes (`codes: [String]`, each error code and warning code it can give), because the SDL and one call cannot list them. Documented on `problems`.
    - Rule 7 builds the expected signature `name(input: NameInput!)` from a verbNoun name and compares the SDL signature to it; a name that is not verbNoun gets the general form.
    - ExampleGraph now obeys rules 7 and 9: ChangeLog-backed `cursor` and `changes(after:)` (NoteChange from IDChange), `deleteNote(id:)` -> `removeNote(input: RemoveNoteInput!)`. NameRewriteTests codedResolverError and GraphQLToolTests toolRefusesASubscription updated for the new fixture shape.
    - Discovery: `IDChange` mapped with Graphiti gives `added/changed/removed: [String!]!`, not `[ID!]!` (Graphiti has no ID type, the toolkit has no ID scalar), so rule 9 flags it. New task ^70231sy adds a toolkit `ID` scalar; `exampleEndpointConforms` carries a rule 9 exception removed by "^70231sy".
    - Heads-up: FoundationModelsACPAgent SettingsGraphTests expects `problems.isEmpty`; with the new default rules it will report rule 7 (`set`, `clear`) and rule 9 until ACPA-17 lands or adds exceptions.
  timestamp: 2026-10-21T11:46:29.547554+00:00
- actor: claude-code
  id: 01m5f4hmqvq5ppbayz9h4cmq7s
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/GraphQL/GraphQLConventions.swift (new), Sources/FoundationModelsExtras/GraphQL/GraphQLTestKit.swift, Tests/FoundationModelsExtrasTests/GraphQL/GraphQLConventionTests.swift (new), Tests/FoundationModelsExtrasTests/GraphQL/ExampleGraph.swift, Tests/FoundationModelsExtrasTests/GraphQL/GraphQLTestKitTests.swift, Tests/FoundationModelsExtrasTests/GraphQL/GraphQLToolTests.swift, Tests/FoundationModelsExtrasTests/GraphQL/NameRewriteTests.swift; `swift test` exit 0: Swift Testing 1412 tests in 138 suites passed, 410 tests in 29 suites passed (plus 131/40/44/26 in the other runners), 0 failures; the only warning is SwiftPM's "missing creator for mutated node" on the mlx-swift_Cmlx bundle, not from this change.
    - next: /review
  timestamp: 2026-10-21T11:46:33.339789+00:00
- actor: claude-code
  id: 01m5f4jsvrcv6a5rsq3xyk4x64
  text: 'How each acceptance box is met: (1) GraphQLConventionTests `conformingSDLHasNoRuleProblem`: an SDL-only fixture that obeys rules 3, 7, 8 and 9 gives no rule problem. It is not a toolkit endpoint, so the older response checks (alias probe, parse failure) still report on it; the full toolkit fixture `ExampleGraph` gives `[]` in `exampleEndpointConforms`, but only with a rule 9 exception until ^70231sy gives the toolkit an `ID` scalar. (2) `ruleBreakNamesItsRule` (15 cases for rules 7 and 9), `codeThatIsNotUpperSnakeBreaksRuleEight`, `scopeThatDisagreesBreaksRuleThree`. (3) `noMutationPassesRuleSeven`. (4) `exceptionRemovesOnlyItsRule`. (5) GraphQLTestKitTests all pass.'
  timestamp: 2026-10-21T11:47:11.352632+00:00
- actor: claude-code
  id: 01m5f4vfc7t3trxyxj37t4gdah
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (dbf4202) — 0 findings, 0 confirmed, 0 refuted; 7 files attempted, 0 failed; 6 .kanban files excluded by .reviewignore
    - next: none — task moved to done
  timestamp: 2026-10-21T11:51:55.527232+00:00
- actor: claude-code
  id: 01m5f4vpy6f6rzezbmczrwkm4v
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files (GraphQLConventions.swift new, GraphQLTestKit.swift, ExampleGraph + 4 test files); follow-up ^70231sy
    - test: green — swift test, 1412 tests in 138 suites, 0 failed
    - commit: dbf4202
    - review: clean — 0 findings
  timestamp: 2026-10-21T11:52:03.270960+00:00
depends_on:
- 01M5F2SBCYPDK97Z605S8T6R5V
position_column: done
position_ordinal: ffb680
title: 'EXTRAS-11: GraphQLEndpointConformance checks the EXTRAS-9 conventions'
---
Spec: TestudoApp/features/packages/foundationmodels-extras.md, EXTRAS-9 (the rules) and EXTRAS-11; D115. Extend `GraphQLEndpointConformance` in Sources/FoundationModelsExtras/GraphQL/GraphQLTestKit.swift so that `problems` also checks the rules of EXTRAS-9 that a machine can check from the SDL and one call.

## Checks (each problem names its rule, for example "rule 9: …")

- Rule 9: a `changes(after: String)` subscription whose event type has `cursor: String!`, `at: DateTime!`, `added: [ID!]!`, `changed: [ID!]!`, `removed: [ID!]!`.
- Rule 9: a root query `cursor: String!`.
- Rule 9: every other argument of `changes` and `cursor` is optional (kanban adds `board` and `filter`).
- Rule 7: each mutation has the form `verbNoun(input: VerbNounInput!)`. An endpoint with no `Mutation` type passes.
- Rule 8: each code of the endpoint is UPPER_SNAKE.
- Rule 3: the scope agrees with rule 3 (`server`: sessions, settings, snapshots; `sessionFolder`: kanban, files, rules, agents, skills).

## Exceptions

An endpoint passes a list of rule exceptions, each with the id of the task that removes it (for example rule 9 with "KANBAN-7"). A problem of an excepted rule is not reported. Skills, agents and kanban already plan rule-9 exceptions. Keep the existing call of `problems` source compatible (exceptions default to none) so endpoints that already call it do not break.

## Acceptance criteria

- [x] A fixture endpoint that obeys every rule has no problems.
- [x] One fixture for each rule that breaks it gives a problem that names that rule.
- [x] No `Mutation` type passes rule 7.
- [x] An exception removes the problems of its rule, and only those.
- [x] Existing conformance tests still pass.

#graphql