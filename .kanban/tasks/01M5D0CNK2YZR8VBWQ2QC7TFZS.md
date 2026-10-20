---
assignees:
- claude-code
depends_on:
- 01M5D0CGJV57JGSRYT78TJ60XA
position_column: done
position_ordinal: ffb080
title: 'EXTRAS-7: GraphQLEndpointTool protocol'
---
Add `GraphQLEndpointTool` to the core target, next to `ForkableTool`. It refines `Tool`, has no associated types, and has one requirement: `var graphQLEndpoints: [any GraphQLEndpoint] { get }`. A tool gives zero, one or more endpoints. A host finds it with `tool as? any GraphQLEndpointTool`.

## Acceptance criteria
- [ ] A test tool that conforms is found through `(tool as any Tool) as? any GraphQLEndpointTool`, and gives its endpoints.
- [ ] A tool that gives zero endpoints and a tool that gives two endpoints both work.
- [ ] A tool that does not conform gives `nil` from the cast. #graphql #feature