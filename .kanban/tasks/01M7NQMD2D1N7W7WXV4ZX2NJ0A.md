---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqq4q06dcb9tpf3wdkgsjb
  text: 'Notify on landing: when this task, ^zyq25p7 and ^3xnx0wv are all on origin/main, send the commit sha with SendMessage to foundationmodelsmultitool-89, foundationmodelsrouter-f1 and testudoapp-9a. Multitool needs shortID, slug, SessionReference.resolve and OutgoingSessionMessage.sourceSession. The Router needs SessionName.default and sourceSession.'
  timestamp: 2026-11-17T21:48:26.720780+00:00
- actor: claude-code
  id: 01m7qbk7k2ycw42rcww24atha1
  text: 'Research: SessionSummary is in Sources/FoundationModelsExtras/Sessions/SessionSummary.swift. The ULID type gives its text with `ulidString`. The tests are in Tests/FoundationModelsExtrasTests/Sessions; SessionFixtures.summary() makes a full summary. Plan: add SessionSlug.swift and SessionName.swift beside SessionSummary.swift, add shortID and slug to SessionSummary, add SessionSlugTests.swift and SessionNameTests.swift, and add shortID and slug tests to SessionSummaryTests.swift. SessionSlug.make uses split on each character that is not a letter or a digit, then joins with a hyphen; split drops the empty parts, thus no hyphen at the start or the end.'
  timestamp: 2026-11-18T12:55:04.546182+00:00
- actor: claude-code
  id: 01m7qbvvdy0dzjf8v25gka4mka
  text: |-
    Implementation done. Added SessionSlug.swift and SessionName.swift, added shortID and slug to SessionSummary, added SessionSlugTests (4 tests), SessionNameTests (5 tests) and 4 tests in SessionSummaryTests. SessionFixtures.summary now takes an optional id.

    Discoveries:
    - At HEAD the build failed in MLXModelLoader.swift because the local Package.resolved (it is gitignored) pinned mlx-swift-lm at 021b934. `swift package update mlx-swift-lm` moved it to stable 8e3daa7 and the build passed. No file in git changed for this.
    - The repo has no .swift-format file. A plain `swift format -i -r` uses 2 spaces and reindents each whole file, but the code uses 4 spaces. I formatted with a copy of the default configuration that sets 4 spaces and lineLength 120, thus the diff holds only the change (and the import order that swift format sets in the two test files).
    - SessionName.default gives an empty name when the agent name has no letter and no digit. The card does not give a rule for that case, thus I did not add one.
  timestamp: 2026-11-18T12:59:47.006879+00:00
- actor: claude-code
  id: 01m7qbvy44dddj1zqpvtegf5gh
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/Sessions/SessionSlug.swift (new), Sources/FoundationModelsExtras/Sessions/SessionName.swift (new), Sources/FoundationModelsExtras/Sessions/SessionSummary.swift, Tests/FoundationModelsExtrasTests/Sessions/SessionSlugTests.swift (new), Tests/FoundationModelsExtrasTests/Sessions/SessionNameTests.swift (new), Tests/FoundationModelsExtrasTests/Sessions/SessionSummaryTests.swift, Tests/FoundationModelsExtrasTests/Sessions/SessionFixtures.swift. 13 new tests. `swift test`: exit 0, 0 failures, 0 compiler warnings (main run 1971 tests in 189 suites passed).
    - next: review
  timestamp: 2026-11-18T12:59:49.764617+00:00
position_column: doing
position_ordinal: '80'
title: 'Session names: shortID, slug and the default-name rule'
---
D199 (b). The TestudoApp brief is `swissarmyhammer/.briefs/at-sessions/extras-brief-at-sessions.md`, item 1. Multitool, Router and the app use these types.

## Current behavior
- `SessionSummary` (`Sources/FoundationModelsExtras/Sessions/SessionSummary.swift`) has `id: ULID` and `title: String?`. It has no short id and no slug.
- No package has a session slug or a session short id helper. The Kanban `ShortID` is internal (7 characters, the last 7 characters of the ULID, in lower case).

## Work
1. Add `SessionSummary.shortID: String`, a computed property: the last 7 characters of the ULID string, in lower case.
2. Add a public `enum SessionSlug` with `static func make(from name: String) -> String`. Rule: lower case; each run of characters that are not letters or digits becomes one hyphen; no hyphen at the start or at the end. Letters with accents stay letters (use `Character.isLetter` / `isNumber`).
3. Add `SessionSummary.slug: String`, a computed property: `SessionSlug.make(from: title ?? "")`. When the result is empty, the slug is `shortID`.
4. Add a public `enum SessionName` with `static func default(agentName: String, usedNames: Set<String>) -> String`. The result is the slug of the agent name (`claude-code`). When `usedNames` has it, the result is the slug with the next free number (`claude-code-2`, `claude-code-3`). The caller gives the names (or slugs) of the sessions in the same folder that are not archived. Compare by slug.

## Tests (Swift Testing)
- [x] "Fix the API tests" gives `fix-the-api-tests`.
- [x] "  --Hello__World!! " gives `hello-world`.
- [x] "!!!" gives the short id as the slug of a summary; `SessionSlug.make` gives "".
- [x] "Café Ünïcode" keeps the letters with accents.
- [x] `shortID` is the last 7 characters in lower case.
- [x] Default name: `claude-code` with no used names; `claude-code-2` when `claude-code` is used; `claude-code-3` when both are used; the agent name "Claude Code" gives `claude-code`.

## Acceptance
- All tests pass. The new types are public and have doc comments. #at-sessions