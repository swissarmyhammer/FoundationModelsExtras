---
assignees:
- claude-code
position_column: doing
position_ordinal: '80'
title: Fork a session on the session directory
---
A fork is a new top-level session of kind `fork`, in the folder of its source, with the agent of the source and a copy of its history up to a cut point.

## Work
- [ ] `SessionForkRequest` (Sendable, Codable, Equatable): `sourceID`, `cut`, `firstPrompt: String?`, `requestedByClient: String?`, `forker: SessionMessageSender`.
- [ ] `SessionForkCut`: `.lastCompletedTurn`, `.callingToolCall`, `.historyPosition(Int)`.
- [ ] `SessionDirectory.fork(_:) async throws -> SessionSummary`, with a default that throws `SessionDirectoryError.forkUnsupported`.
- [ ] Errors: `unknownSession` for an unknown source; a new `archivedSession` for an archived source; a new `forkCutOutOfRange`.
- [ ] `SessionName` gets the fork default name: the slug of the source name plus `-fork`, then `-fork-2`, `-fork-3`. Archived sessions do not count.
- [ ] A fork sends `started` with kind `fork` and `parentID` = source.
- [ ] `InMemorySessionDirectory.fork(_:)`: same folder and agent, the fork name, `parentID` = source. It records the cut and the first prompt for tests.

## Tests
- [ ] Fork: kind `fork`, parent, folder, agent, name `<slug>-fork`.
- [ ] A second fork: `<slug>-fork-2`. With the first fork archived: `<slug>-fork` again.
- [ ] Unknown source and archived source give the errors.
- [ ] The `started` event of a fork.
- [ ] A conformer with no `fork(_:)` throws `forkUnsupported`.
- [ ] `Codable` round trip of the request and the cut. #fork