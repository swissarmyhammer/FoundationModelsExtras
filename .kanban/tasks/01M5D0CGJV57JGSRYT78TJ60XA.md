---
assignees:
- claude-code
position_column: done
position_ordinal: ffaf80
title: 'EXTRAS-2 and EXTRAS-5: GraphQLEndpoint protocol and GraphQLViewer'
---
Add the `GraphQLEndpoint` protocol to the core `FoundationModelsExtras` target, in a new folder `Sources/FoundationModelsExtras/GraphQL/`.

- The core target links `GraphQL` (GraphQLSwift, from 4.3.0), `Graphiti` (from 3.1.0) and `OrderedCollections` (swift-collections). Use the same version floors as FoundationModelsKanban. Add the three products to the allowlist of `TelemetryDependencyTests`.
- `GraphQLEndpointScope`: `sessionFolder` and `server`. The raw values are `"sessionFolder"` and `"server"`, the same as `SAH.GraphQL.Scope` of FoundationModelsACP (ACP-5).
- `GraphQLEndpoint: Sendable`: `name: String`, `version: String`, `scope: GraphQLEndpointScope`, `schema: String` (the SDL). `execute(query:variables:operationName:viewer:) async throws -> String` gives the JSON result. `subscribe(query:variables:operationName:viewer:) async throws -> AsyncThrowingStream<String, Error>` gives one JSON String for each event. `variables` is `[String: Map]`.
- `GraphQLViewer` (EXTRAS-5): the client id, the trust (`userDevice` or `external`), the sessions that this client owns, and the sessions that any client owns. No ACP type. `viewer` is optional: `nil` is the agent of the session itself (a model tool call), which has no client.
- `GraphQLEndpointDescription`: a Codable value with name, version, scope and schema, with the JSON keys of `SAH.GraphQL.Endpoint`, so that a host can list the endpoints.

## Acceptance criteria
- [ ] A test endpoint conforms, and its description encodes to the JSON shape of `SAH.GraphQL.Endpoint` (`name`, `version`, `scope`, `schema`).
- [ ] The scope raw values are `sessionFolder` and `server`.
- [ ] The allowlist test of the core target passes with the new products.
- [ ] `swift build` and the tests pass. #graphql #feature