---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qc93f3tqnz4z5mjkp90frs
  text: 'Scope change: work item 3 (the header in the mail of a user message with a source session) moved to ^3xnx0wv, because the review of ^3xnx0wv requires the header for the send doc. Before you start this task, read the ^3xnx0wv commit. Do only the work items that remain: the default name at launch, and the inbox for a recorded target.'
  timestamp: 2026-11-18T13:07:01.219145+00:00
depends_on:
- 01M7NQMD2D1N7W7WXV4ZX2NJ0A
- 01M7NQN30QZVJ438F3S3XNX0WV
position_column: doing
position_ordinal: '8680'
title: InMemorySessionDirectory follows the D199 send contract and gives default names
---
D199. The brief is `swissarmyhammer/.briefs/at-sessions/extras-brief-at-sessions.md`, item 4. Consumers test against this double, so it must follow the new contract of `SessionDirectory.send`.

## Current behavior
- `InMemorySessionDirectoryState.launch` (`Sessions/InMemorySessionDirectoryState.swift`, about line 111) uses `request.title`, which can be `nil`. A new session gets no name.
- `deliver` (`Sessions/InMemorySessionDirectoryState+Messages.swift`, about line 207) restores a recorded target through the launcher and then starts a turn or queues the message. The Router puts the message in the inbox of a recorded target.
- `InMemorySessionDirectory.mail(carrying:)` (`Sessions/InMemorySessionDirectory+Mail.swift`) renders no sender header.
- `record` does not copy a source session into `SessionMessage`.

## Work
1. In `launch`, when the request has no title, set the title to `SessionName.default(agentName:usedNames:)`. The agent name is the resolved agent id (or the agent name of the launcher, if it gives one). The used names are the slugs of the sessions in the same working folder that are not archived.
2. In `record`, copy `OutgoingSessionMessage.sourceSession` into `SessionMessage.sourceSession` (only for a `.user` sender), so `messageDelivered` carries it.
3. Header: for a `.user` message with a source session, `mail(carrying:)` puts a header before the text that names the source session ("From the user, in <title> (<folder>)"). The body stays `.userMessage`. Because `mail(carrying:)` is static, give it the source summary (for example an extra parameter, or an instance function that looks up the summary). Keep the old behavior for a user message with no source session. Update the doc comment.
4. Recorded target: decide with the Router contract. The target gets the message in its inbox (`inbox(of:)` gives it) and the send is not refused, for a session sender and for a user sender. Check whether the restore path must stay for other tests; if a test needs it, keep it behind the launcher and state the behavior in the doc.

## Tests (Swift Testing)
- [ ] A start with no title in an empty folder gives `claude-code` (with an agent `claude-code`); a second start in the same folder gives `claude-code-2`; a start in another folder gives `claude-code`; an archived `claude-code` does not count.
- [ ] A start with a title keeps the title.
- [ ] A user message with a source session to a live target: the mail has the header, and `messageDelivered` has `sourceSession`.
- [ ] A user message with no source session: no header (as before).
- [ ] A user message with a source session to a recorded target: the receipt is not `refused`, and `inbox(of:)` has the message.

## Acceptance
- All tests of the package pass. Check other packages for tests that use `InMemorySessionDirectory` and expect the old restore or the `nil` title, and write down what they must change. #at-sessions