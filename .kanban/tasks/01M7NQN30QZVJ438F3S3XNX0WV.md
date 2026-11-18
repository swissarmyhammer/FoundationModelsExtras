---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqq76tmc8q9d5ghwavr3bv
  text: 'Notify on landing: when this task, ^zx2nj0a and ^zyq25p7 are all on origin/main, send the commit sha with SendMessage to foundationmodelsmultitool-89, foundationmodelsrouter-f1 and testudoapp-9a.'
  timestamp: 2026-11-17T21:48:29.274969+00:00
position_column: doing
position_ordinal: '8180'
title: Source session on an outgoing and a delivered message, and the send contract doc
---
D199. The brief is `swissarmyhammer/.briefs/at-sessions/extras-brief-at-sessions.md`, items 3 and 5. The Router and ACPAgent (ACPA-6) use these fields.

## Current behavior
- `OutgoingSessionMessage` (`Sessions/OutgoingSessionMessage.swift`) has `from`, `to`, `text` and `inReplyTo`. A `.user` sender has no source session.
- The event `SessionDirectoryEvent.messageDelivered(SessionMessage)` already exists, so no new event is necessary. But `SessionMessage` (`Sessions/SessionMessage.swift`) has no source session, so the host of the target cannot show where a user message comes from.
- The doc of `SessionDirectory.send` (`Sessions/SessionDirectory.swift`, about lines 74-95) says that the directory renders a header with "the user". The Router renders no header for a user sender, and refuses a user sender to a recorded target.
- The doc of `SessionAddress.agent` says "the newest live root session of the agent". After D199 the Router always starts a new session for `.agent`.

## Work
1. Add `OutgoingSessionMessage.sourceSession: ULID?` (init default `nil`). It has a meaning only for a `.user` sender: the session in which the user wrote the message. Decode a missing key as `nil` (`decodeIfPresent`).
2. Add `SessionMessage.sourceSession: ULID?` with the same Codable rule, so that `messageDelivered` carries the sender, the source session and the text.
3. Update the doc of `SessionDirectory.send`: a session sender gets a header with the title, agent and folder of the sender; a user sender with no source session gets no header; a user sender with a source session gets a header that names the source session ("From the user, in <title> (<folder>)"), and the body stays a user message; a recorded target gets the message in its inbox for a session sender and for a user sender.
4. Update the doc of `SessionAddress.agent`: the directory starts a new root session of the agent; `@<agent name>` is the slug of the session of that agent.
5. Doc of `messageDelivered`: the host of the target uses it to show the message.

## Tests (Swift Testing)
- [ ] `OutgoingSessionMessage` decodes old JSON with no `sourceSession` key as `nil`.
- [ ] `SessionMessage` decodes old JSON with no `sourceSession` key as `nil`.
- [ ] Both round-trip a non-nil `sourceSession`.

## Acceptance
- All tests pass. Existing call sites compile with no change (default arguments). #at-sessions