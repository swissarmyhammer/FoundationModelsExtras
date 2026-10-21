---
assignees:
- claude-code
depends_on:
- 01M5F2SBCYPDK97Z605S8T6R5V
position_column: todo
position_ordinal: '8180'
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

- [ ] A fixture endpoint that obeys every rule has no problems.
- [ ] One fixture for each rule that breaks it gives a problem that names that rule.
- [ ] No `Mutation` type passes rule 7.
- [ ] An exception removes the problems of its rule, and only those.
- [ ] Existing conformance tests still pass.

#graphql