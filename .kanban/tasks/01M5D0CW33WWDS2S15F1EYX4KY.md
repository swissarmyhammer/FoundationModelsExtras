---
assignees:
- claude-code
depends_on:
- 01M5D0CGJV57JGSRYT78TJ60XA
position_column: done
position_ordinal: ffb180
title: 'EXTRAS-6a: coded errors, warnings, scalars and the response encoding'
---
Move the general response parts of the Kanban GraphQL layer (FoundationModelsKanban `Sources/FoundationModelsKanban/GraphQL/`) to `Sources/FoundationModelsExtras/GraphQL/`, as public API:

- `CodedError`: a protocol with `code` and `message`. The toolkit errors `GraphQLToolkitError`: `INVALID_VARIABLES`, `SUBSCRIPTION_NOT_IN_TOOL`, `GRAPHQL_PARSE_FAILED`, `GRAPHQL_VALIDATION_FAILED`, `AMBIGUOUS_NAME`, `INTERNAL`. Not `CONTENT_BY_AGENT_ONLY` (D99). The `GraphQLError` extensions `coded(as:)`, `codedAsParseFailure()` and `codedAsResultError()` work with each `CodedError`, so a package keeps its own error enum (for example `KanbanError`).
- The error-only response JSON of a coded error, with the warnings in `extensions.warnings`.
- `ResponseWarning`, `ResponseWarnings` (actor) and `ResolverWarnings` (task local collector).
- `DateTime` (RFC 3339 UTC with milliseconds) and `JSONScalar`, and a `SchemaBuilder` step that adds the `DateTime` and `JSON` scalars.
- `GraphQLResponse`: encodes `data`, `errors`, and `extensions` with `rewrites`, `warnings`, and more keys that an endpoint adds (for example `txn` of `kanban`).

## Acceptance criteria
- [ ] Tests port the general cases of the Kanban tests: the codes, the coded `GraphQLError`, the warnings order, the `DateTime` round trip, the sorted keys of `JSON`, and the response with and without `extensions`.
- [ ] A package error type that conforms to `CodedError` keeps its code in `extensions.code`. #graphql #feature