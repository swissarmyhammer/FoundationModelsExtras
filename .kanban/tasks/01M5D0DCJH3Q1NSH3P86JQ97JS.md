---
assignees:
- claude-code
depends_on:
- 01M5D0D3YX4VQVQZS178ET54CF
- 01M5D0CNK2YZR8VBWQ2QC7TFZS
position_column: done
position_ordinal: ffb380
title: 'EXTRAS-6c: the engine run, the tool wrapper and the test kit'
---
- The engine run: an extension of the Graphiti `API` whose context conforms to `GraphQLRunContext` (it has a `ResponseWarnings`). `respond(to:variables:operationName:rules:formattedWith:context:)` and `subscribe(...)` apply the name rewrite, run the document, put the result back in the form of the caller, code each error, and encode the response with `extensions.rewrites` and `extensions.warnings`. This is the run of `PublicSchema` of Kanban, with the rules as an argument.
- The tool wrapper: `GraphQLArguments` (the forgiving decode of Kanban `KanbanArguments`: `variables` as an object, as JSON text, or in a code fence; else `INVALID_VARIABLES`), and `GraphQLTool`: a `Tool` and a `GraphQLEndpointTool` over one endpoint. One document in, one `{data, errors}` out, `SUBSCRIPTION_NOT_IN_TOOL` for a subscription. It calls the endpoint with no viewer.
- The test kit (public, in the core target, D73): `GraphQLSchemaGolden` (compare an SDL with a golden file; write the file when the environment asks for it), `GraphQLSchemaDescriptions` (each type, field, argument, input field and enum value with no description), and `GraphQLEndpointConformance` (name, version, scope, SDL that parses and is the same as the schema of the engine, a `__typename` call, and a call with an alias name that the endpoint answers and reports in `extensions.rewrites`). Each check gives a list of problems, so that it needs no test framework.

## Acceptance criteria
- [ ] An example endpoint in the tests, built only from the toolkit, passes the conformance check, including the alias call.
- [ ] `GraphQLTool` over the example endpoint answers a query, gives `INVALID_VARIABLES` and `SUBSCRIPTION_NOT_IN_TOOL`, and gives its endpoint through `GraphQLEndpointTool`.
- [ ] The golden and description checks report a changed SDL and a missing description. #graphql #feature