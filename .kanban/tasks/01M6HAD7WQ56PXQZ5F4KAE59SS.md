---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A tool can read the transcript of a session from ToolContext
---
A tool must be able to read the recorded events of a session through ToolContext. This is a second task. Do not mix it with the failure value task. Start it after that task is done.

Constraint: the transcript types (TranscriptEvent, TranscriptEntryPayload) are in FoundationModelsRouter. Router depends on Extras, so Extras cannot import them.

Plan (option a, additive):
- Extras defines a public protocol `SessionTranscriptReader: Sendable` with one call, `transcript(of sessionID: ULID) async throws -> SessionTranscript`.
- Extras defines a small public result type `SessionTranscript` (Sendable, Equatable, Codable): the session id, and an ordered list of entries. Each entry has a kind string, a timestamp and a JSON payload (`OperationValue` can carry it). The host maps its own event types into it.
- The host (Router or the ACP agent) gives the reader when it makes the run plane or the MountSite. Without a reader, the call throws a clear error: no transcript source.
- ToolContext gets `transcript(of:)`, which calls the reader of the site.

Decisions of the user:
1. Which sessions: any session that the hosting Router can give. Extras adds no tree rule and no check of sessionID, parentSessionID or rootSessionID. The host (the reader) decides which ids it can give. An id that the host does not know throws a clear not-found error (a public error case in Extras, for example `SessionTranscriptError.notFound(ULID)`). Without a reader, the error is `SessionTranscriptError.noSource`.
2. Running session: the reader gives only what is on disk. It does not flush. The protocol doc must say that a running session may lack its latest events.

Router change: the user has not allowed one for this task. Extras alone ships the protocol, the type and the errors. The host part needs a later decision.

Option b (move the event types into Extras) is not planned: it is a breaking move.

Acceptance: tests with a fake reader (a known id reads, an unknown id gives notFound, a missing reader gives noSource), and a Codable round trip of SessionTranscript.