---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qvhx57xwy8a5w6jzwh8spy
  text: 'Research: SessionDirectoryError has no case for an archived session, thus fork adds `archivedSession(ULID)`, `forkCutOutOfRange(SessionForkCut)` and `forkUnsupported`. No exhaustive switch over SessionDirectoryError is in Sources or Tests. The only conformers of SessionDirectory in this package are InMemorySessionDirectory and the test type DirectoryWithNoPins (it gets the default fork). SessionDirectoryOrigin already has `fork`. The state has a private `usedNames(in:)` and a private `insert(_:requestedByClient:)`; the fork code reuses both. The fork name reuses the number loop of `SessionName.default` through one shared private helper. In-memory cut rule: `.historyPosition(n)` with n < 0 throws; `.callingToolCall` throws unless the source works; `.lastCompletedTurn` always gives a fork. The directory records the full fork request for the tests (`forkRequest(of:)`).'
  timestamp: 2026-11-18T17:33:58.311630+00:00
- actor: claude-code
  id: 01m7qvxb739hdr2nqc6ersdxzw
  text: |-
    ### implement — changed
    - evidence: 14 files. New: Sources/FoundationModelsExtras/Sessions/SessionForkCut.swift, SessionForkRequest.swift, InMemorySessionDirectoryState+Fork.swift; Tests/FoundationModelsExtrasTests/Sessions/InMemorySessionDirectoryForkTests.swift, SessionForkRequestTests.swift. Changed: SessionDirectory.swift, SessionDirectoryError.swift, SessionName.swift, InMemorySessionDirectory.swift, InMemorySessionDirectory+TestHooks.swift, InMemorySessionDirectoryState.swift, SessionDirectoryDefaultsTests.swift, SessionDirectoryErrorTests.swift, SessionNameTests.swift. `swift test`: 7 runs passed (184, 43, 46, 26, 451, 2078, 37 tests), 0 failures, no warnings in the session files. `swift format lint` clean on the changed files. Committed on branch worktree-agent-a896802300545a72b. This card file is only in the .kanban folder of the main checkout, thus the commit does not hold it.
    - next: review
  timestamp: 2026-11-18T17:40:13.155044+00:00
position_column: done
position_ordinal: fffc80
title: Fork a session on the session directory
---
A fork is a new top-level session of kind `fork`, in the folder of its source, with the agent of the source and a copy of its history up to a cut point.

## Work
- [x] `SessionForkRequest` (Sendable, Codable, Equatable): `sourceID`, `cut`, `firstPrompt: String?`, `requestedByClient: String?`, `forker: SessionMessageSender`.
- [x] `SessionForkCut`: `.lastCompletedTurn`, `.callingToolCall`, `.historyPosition(Int)`.
- [x] `SessionDirectory.fork(_:) async throws -> SessionSummary`, with a default that throws `SessionDirectoryError.forkUnsupported`.
- [x] Errors: `unknownSession` for an unknown source; a new `archivedSession` for an archived source; a new `forkCutOutOfRange`.
- [x] `SessionName` gets the fork default name: the slug of the source name plus `-fork`, then `-fork-2`, `-fork-3`. Archived sessions do not count.
- [x] A fork sends `started` with kind `fork` and `parentID` = source.
- [x] `InMemorySessionDirectory.fork(_:)`: same folder and agent, the fork name, `parentID` = source. It records the cut and the first prompt for tests.

## Tests
- [x] Fork: kind `fork`, parent, folder, agent, name `<slug>-fork`.
- [x] A second fork: `<slug>-fork-2`. With the first fork archived: `<slug>-fork` again.
- [x] Unknown source and archived source give the errors.
- [x] The `started` event of a fork.
- [x] A conformer with no `fork(_:)` throws `forkUnsupported`.
- [x] `Codable` round trip of the request and the cut. #fork