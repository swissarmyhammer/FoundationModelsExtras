---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqq76tmc8q9d5ghwavr3bv
  text: 'Notify on landing: when this task, ^zx2nj0a and ^zyq25p7 are all on origin/main, send the commit sha with SendMessage to foundationmodelsmultitool-89, foundationmodelsrouter-f1 and testudoapp-9a.'
  timestamp: 2026-11-17T21:48:29.274969+00:00
- actor: claude-code
  id: 01m7qc490em2z1n5qm1hys9sh6
  text: |-
    Discoveries:
    - The synthesized Codable of an Optional property already uses decodeIfPresent. Thus a missing `sourceSession` key decodes as nil with no custom init(from:). The tests prove it: they encode a message, remove the key from the JSON, and decode it.
    - InMemorySessionDirectory renders no sender header. The header rules in the doc of `send` apply to the Router. The in-memory directory now copies `sourceSession` into the delivered message (`record` in InMemorySessionDirectoryState+Messages.swift).
    - InMemorySessionDirectory still delivers an `.agent` address to the newest live root session. That does not agree with the new doc of `SessionAddress.agent`. New task ^ps0p045 records this work.
    - The repository has no `.swift-format` file. `swift format -i` with no configuration indents with 2 spaces and wraps at 100 columns, and it rewrites whole files. The project files use 4 spaces and 120 columns. I formatted with a temporary configuration `{"indentation":{"spaces":4},"lineLength":120}`. This configuration gives no change on the source files at HEAD. I kept the old import order and two old lines in the delivery tests, because the formatter changed lines that this task does not touch.
  timestamp: 2026-11-18T13:04:23.054920+00:00
- actor: claude-code
  id: 01m7qc4c13y0q1py65dredf88j
  text: |-
    ### implement — changed
    - evidence: commit 8aa993be77f88b2ac0a925d6be8b7ef282205d13 on branch worktree-agent-a9298487e8575f506 (not pushed). 9 files: Sessions/OutgoingSessionMessage.swift, SessionMessage.swift, SessionDirectory.swift, SessionAddress.swift, SessionDirectoryEvent.swift, InMemorySessionDirectoryState+Messages.swift; tests SessionMessageTests.swift (+4), InMemorySessionDirectoryDeliveryTests.swift (+1), SessionFixtures.swift (decodeWithout helper). `swift build --build-tests` has no errors and no warnings. `swift test --filter FoundationModelsExtrasTests`: 1968 tests in 188 suites passed.
    - next: /review
  timestamp: 2026-11-18T13:04:26.147678+00:00
- actor: claude-code
  id: 01m7qc867cd12gwd9n0emk7v1x
  text: |-
    ### review — findings
    - evidence: review sha 6a42870~1..6a42870; 1 finding (1 confirmed, 2 refuted) — Sources/FoundationModelsExtras/Sessions/SessionDirectory.swift:93
    - next: implement the open finding in the 2026-11-18 07:05 Review Findings section, then review again.
  timestamp: 2026-11-18T13:06:31.276532+00:00
- actor: claude-code
  id: 01m7qckdsa9x1gzr78wxh3y0vt
  text: |-
    Discoveries and design for the open finding:
    - The sibling packages have no use of `InMemorySessionDirectory.mail(carrying:`. The only caller was the Extras test `theMailFollowsTheBodyChoiceRule` in InMemorySessionDirectoryDeliveryTests.swift. The Router has its own private `mail(id:carrying:from:inReplyTo:)` and its own JSON header (`AgentMessageHeader`, `[sender facts] ` marker). That code is not changed.
    - The send of the in-memory directory throws `unknownSession` for an unknown session sender, but it does not check the source session. Thus `mail(carrying:)` does not throw: when the directory does not know the named session, the header names only the session id (the same choice as the Router).
    - Design: the static `mail(carrying:)` became an instance function, because it must read the summaries. New internal type `SessionSenderHeader` (Sessions/SessionSenderHeader.swift) holds the one header format. Header: `From the session <title>, agent <agent> (<folder>)` for a session sender; `From the user, in <title> (<folder>)` for a user sender with a source session; no header for a user sender with no source session. A blank line separates header and text. No title gives the short id; no agent name gives the agent id.
    - The old static-function test was replaced by the new suite InMemorySessionDirectoryMailTests (6 tests, exact Mail equality).
  timestamp: 2026-11-18T13:12:39.466319+00:00
- actor: claude-code
  id: 01m7qckh78zaf8ydp2er45te80
  text: |-
    ### implement — changed
    - evidence: 5 files (not committed) — Sources/FoundationModelsExtras/Sessions/SessionSenderHeader.swift (new), Sessions/InMemorySessionDirectory+Mail.swift, Sessions/InMemorySessionDirectory.swift (doc), Tests/FoundationModelsExtrasTests/Sessions/InMemorySessionDirectoryMailTests.swift (new, 6 tests), InMemorySessionDirectoryDeliveryTests.swift (old static-mail test removed). RED: 5 of 6 new tests failed before the header code. `swift build --build-tests`: no errors, no warnings. `swift test --filter FoundationModelsExtrasTests`: 1985 tests in 190 suites passed. Dependent uses of `InMemorySessionDirectory.mail(carrying:` in sibling packages: none. Finding of 2026-11-18 07:05 is checked.
    - next: /review
  timestamp: 2026-11-18T13:12:42.984241+00:00
position_column: doing
position_ordinal: '8380'
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
- [x] `OutgoingSessionMessage` decodes old JSON with no `sourceSession` key as `nil`.
- [x] `SessionMessage` decodes old JSON with no `sourceSession` key as `nil`.
- [x] Both round-trip a non-nil `sourceSession`.

## Acceptance
- All tests pass. Existing call sites compile with no change (default arguments). #at-sessions

## Review Findings (2026-11-18 07:05)

> Scope: `review sha 6a42870~1..6a42870` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 0 not reviewed.

- [x] `Sources/FoundationModelsExtras/Sessions/SessionDirectory.swift:93` `completeness/invariant-propagation` — The doc of send says a user sender with a source session gets a sender header that names the source session. No code in the change renders this header. The Mail code that builds the mail body was not changed. So a message with a source session is delivered with no header, and the documented rule is not applied. Render the header in the mail builder for a user sender with a source session, and for a session sender. Add a test that reads the mail body and asserts the header. If the header is not wanted in this change, remove the header rules from the send doc.
