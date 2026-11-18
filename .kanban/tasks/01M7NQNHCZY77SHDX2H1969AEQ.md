---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qc93f3tqnz4z5mjkp90frs
  text: 'Scope change: work item 3 (the header in the mail of a user message with a source session) moved to ^3xnx0wv, because the review of ^3xnx0wv requires the header for the send doc. Before you start this task, read the ^3xnx0wv commit. Do only the work items that remain: the default name at launch, and the inbox for a recorded target.'
  timestamp: 2026-11-18T13:07:01.219145+00:00
- actor: claude-code
  id: 01m7qd2rqhnxm302amwzp814ss
  text: |-
    Research (worktree from local main 988ade6):
    - Work item 2 (record copies sourceSession) is done already: record passes message.sourceSession. Work item 3 (header) is done in 875ace0. This pass does the default name and the inbox for a recorded target.
    - Start paths: only `launch` makes a new session (start, and an agent-address send through sendToAgent). Restore and fork exist only as the `register` test hook, which takes a summary that the test made; it makes no new session, thus it gets no default name.
    - The launcher has no agent names. The default name uses the resolved agent id.
    - Router contract (RouterSessionDirectory.sendToRecorded): a recorded target gets an inbox file, the receipt is `sent`, the directory restores nothing, and `messageDelivered` comes later, when a host opens the session. The in-memory double follows this: outcome `sent`, no `messageDelivered` and no `started` at the send. The Router still refuses a user sender; the SessionDirectory.send doc now says a user sender is stored too, thus the Router must change on its own.
    - `InMemorySessionDirectory.Refusal.noLauncher` has no use after the restore goes. No sibling package uses it (only Multitool uses Refusal, with noSessionInTheFolder and tooManySends).
    - Sibling search: only FoundationModelsMultitool tests use InMemorySessionDirectory. None registers a summary with isLive false, and none expects a nil title after a start (SessionsGraphMutationTests compares the tool and the graph, which both get the same default name).
  timestamp: 2026-11-18T13:21:02.193796+00:00
- actor: claude-code
  id: 01m7qdm876x4d9affyj9r203h3
  text: |-
    ### implement — changed
    - evidence: commit 9d81ca8 in worktree agent-afe540afc8766f188 (branch worktree-agent-afe540afc8766f188, on 988ade6), not pushed. `swift test --filter FoundationModelsExtrasTests`: 1996 tests in 190 suites passed, no warnings in the changed files.
    - Files: InMemorySessionDirectoryState.swift (launch gives the default name; usedNames(in:)), InMemorySessionDirectoryState+Messages.swift (deliver stores mail for a recorded target, receipt `sent`, no event; restore removed; store(...) split from record), InMemorySessionDirectory.swift (class doc), InMemorySessionDirectory+Refusal.swift (noLauncher removed: no use left), SessionDirectoryEvent.swift (messageDelivered doc: a stored message sends no event at the send). Tests: InMemorySessionDirectoryStartTests (5 new), InMemorySessionDirectoryDeliveryTests (6 new recorded tests, 1 agent-address name test), InMemorySessionDirectoryFixtures (agent claude-code).
    - Changed existing tests: "a message to a recorded session restores it, then delivers" and "a message to a recorded session with no launcher is refused" are replaced by the inbox tests.
    - A start with a title keeps it: the existing test "a start of a known agent gives a live root session..." asserts title "Review".
    - Dependent tests in sibling packages: none found. Only FoundationModelsMultitool tests use InMemorySessionDirectory; none registers a recorded session or expects a nil title after a start.
    - Follow-up outside this package: RouterSessionDirectory.sendToRecorded still refuses a user sender, but the SessionDirectory.send doc says a user sender is stored too.
    - next: /review
  timestamp: 2026-11-18T13:30:35.110553+00:00
- actor: claude-code
  id: 01m7qdrcpwx4x661170cgxghp4
  text: |-
    ### review — clean
    - evidence: `review sha 026fb45~1..026fb45`: 8 files reviewed, 0 not reviewed. Counts: 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed, 0 skipped. No prior review findings on the task.
    - next: none. The task moved to done.
  timestamp: 2026-11-18T13:32:50.780708+00:00
depends_on:
- 01M7NQMD2D1N7W7WXV4ZX2NJ0A
- 01M7NQN30QZVJ438F3S3XNX0WV
position_column: done
position_ordinal: fff680
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