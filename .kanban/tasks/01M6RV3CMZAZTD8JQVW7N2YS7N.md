---
assignees:
- claude-code
position_column: done
position_ordinal: ffd180
title: 'Add GraphQLActor: the identity of the person in GraphQLViewer'
---
Step 1 of 5 (Extras, ACPClient, ACPAgent, Kanban, KanbanViewKit). A tunnel call has a GraphQLViewer, but the viewer has no person. Thus an endpoint cannot tell the edits of the person from the edits of the agent.

Do these steps:
- Add `public struct GraphQLActor: Codable, Hashable, Sendable` with `id`, `name` and `aliases`. An alias is an earlier id of the same person.
- Add `public var actor: GraphQLActor?` to GraphQLViewer. The init default is nil. Decode it with decodeIfPresent, so that an old payload decodes.
- Add `GraphQLActor.initializeMetaKey = "sah/actor"` and generic Codable helpers to and from a `_meta` JSON object. ACPClient and ACPAgent use them.
- Optional: a Graphiti type helper so that each endpoint exposes `viewer { actor { id name aliases } }` in the same form.

Acceptance:
- Deterministic tests: Codable round trip, old payload with no actor, meta helpers.
- The package builds and its tests pass. Push, and give the commit to swissarmyhammer-75.

Status: wait for the design approval from swissarmyhammer-75 before code. #graphql