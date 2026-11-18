---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqq5znzhcpwn8jphd0rnmr
  text: 'Notify on landing: when this task, ^zx2nj0a and ^3xnx0wv are all on origin/main, send the commit sha with SendMessage to foundationmodelsmultitool-89, foundationmodelsrouter-f1 and testudoapp-9a.'
  timestamp: 2026-11-17T21:48:28.021183+00:00
- actor: claude-code
  id: 01m7qbzbh1g24c6hg95zj98e0y
  text: 'Research: the worktree did not have f40b6c0, thus I cherry-picked it (SessionSummary.shortID, SessionSummary.slug, SessionSlug.make). SessionSummary has var title, var workingDirectory and var state, thus a test can change a SessionFixtures.summary(id:). ULID(ulidString:) parses the text of an id; the resolver makes the text upper case before it parses it. The rule for the scopes: for each kind (short id, then slug), the resolver looks first in the source folder, then in all sessions. The new code goes in Sessions/SessionReference.swift and Sessions/SessionReferenceResolution.swift; the tests go in Sessions/SessionReferenceTests.swift.'
  timestamp: 2026-11-18T13:01:41.793955+00:00
depends_on:
- 01M7NQMD2D1N7W7WXV4ZX2NJ0A
position_column: doing
position_ordinal: '8280'
title: 'SessionReference.resolve: one pure resolver for @id, @short id and @slug'
---
D199 (e): an agent IS a session. The brief is `swissarmyhammer/.briefs/at-sessions/extras-brief-at-sessions.md`, item 2. The composer of the app and the `send` of the Multitool `sessions` tool use this resolver.

## Work
Add a public `enum SessionReference` in `Sources/FoundationModelsExtras/Sessions/` with:

```swift
static func resolve(_ text: String, sourceFolder: URL?, among summaries: [SessionSummary]) -> SessionReferenceResolution
```

and a public `enum SessionReferenceResolution: Sendable, Equatable` with `.session(SessionSummary)`, `.ambiguous([SessionSummary])` and `.none`.

Rules:
- A leading `@` is optional. Trim white space.
- The order is: a full ULID (any letter case), then a short id, then a slug. When the text is a full ULID, the resolver does not look at slugs: a ULID with no match gives `.none`.
- A short id or a slug first looks at the sessions whose `workingDirectory` is `sourceFolder`. Compare the folders with symbolic links resolved and no trailing `/`. When no session matches there, it looks at all `summaries`.
- Two or more matches in the first scope that has a match give `.ambiguous` (in the order of `summaries`).
- A session with the state `.archived` never matches.
- There is no agent step. `.none` lets the caller start an agent.
- The function is pure: it reads only its arguments (the folder compare can use `URL.resolvingSymlinksInPath()`).
- Short id and slug compares are in lower case.

## Tests (Swift Testing)
- [ ] A full id in upper case and in lower case resolves.
- [ ] `@x` and `x` give the same result.
- [ ] An id that is also the slug of another session gives the session with the id.
- [ ] A short id that two sessions share gives `.ambiguous`.
- [ ] A slug in the source folder wins over the same slug in another folder.
- [ ] The same slug two times in the source folder gives `.ambiguous`.
- [ ] A slug only in another folder resolves.
- [ ] A source folder with a trailing `/` or a symbolic link matches.
- [ ] An archived session never matches (id, short id or slug).
- [ ] No match gives `.none`; an empty text gives `.none`.

## Acceptance
- All tests pass. The public API has doc comments that state the rules. #at-sessions