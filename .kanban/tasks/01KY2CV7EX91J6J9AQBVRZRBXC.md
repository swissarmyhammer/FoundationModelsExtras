---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky2j9ngvfeve7gbtp50v1wwg
  text: |-
    Implemented Wildmatch.swift (internal enum) + WildmatchTests.swift (84 table-driven cases + pathological-pattern timing test). swift test --filter WildmatchTests and full swift test both green (154 tests total). Checkpoint commit 4a87706.

    Design notes:
    - Pattern split into `/`-delimited segments; a segment is `.doubleStar` iff its raw (unescaped) text is exactly "**" — anything else (e.g. "a**b") tokenizes to two star tokens, which naturally degrades to single-* behavior, satisfying "any other ** behaves like *".
    - Segment composition uses a DP table dp[i][j] over segment counts (not characters) so multiple ** components stay polynomial, not exponential.
    - Chose "zero or more" semantics for leading/interior/sole ** (so **/foo matches foo, a/**/b matches a/b) and "one or more" for a genuinely trailing ** (abc/** does NOT match bare "abc", only abc/x, abc/x/y, ...) per gitignore(5)'s literal "matches everything inside" wording. This is a judgment call where I couldn't fully verify byte-for-byte against git's actual t3070-wildmatch.sh (no git source checked out here) — flagging in case a future task surfaces a conflicting real-world case.
    - Within-segment matching uses the classic iterative two-pointer backtrack-with-rewind algorithm (star index + resumable match index) rather than recursion, which is what makes the pathological a*a*a*...*b vs long-run-of-a's case O(n*m) instead of exponential.
    - Malformed brackets (unterminated [, unterminated [:name:) return nil through the whole parse chain, so wildmatch() returns false without throwing/crashing.
  timestamp: 2026-07-21T14:46:51.675806+00:00
position_column: doing
position_ordinal: '80'
title: 'Wildmatch: gitignore glob matching engine (*, ?, [...], **)'
---
## What
Create `Sources/FoundationModelsExtras/Wildmatch.swift` — an internal, pure, dependency-free pattern matcher implementing git's wildmatch semantics for a pattern against a `/`-separated relative path. Do NOT use `fnmatch(3)` or `NSPredicate`; git's `**` and slash rules differ from both.

Function: `func wildmatch(pattern: String, path: String) -> Bool` (internal; module-level or namespaced enum, matching prevailing style). Non-throwing — every input has a defined result.

Semantics (from `gitignore(5)` PATTERN FORMAT and git's wildmatch):
- `*` matches anything except `/`
- `?` matches any single character except `/`
- `[...]` character classes: literals, ranges (`[a-z]`), negation via BOTH `[!...]` and `[^...]` (git accepts both), and the named POSIX classes `[[:alnum:]]`, `[[:alpha:]]`, `[[:blank:]]`, `[[:cntrl:]]`, `[[:digit:]]`, `[[:graph:]]`, `[[:lower:]]`, `[[:print:]]`, `[[:punct:]]`, `[[:space:]]`, `[[:upper:]]`, `[[:xdigit:]]` (map to `Character`/ASCII predicates). A malformed class (e.g. unterminated `[`) matches nothing — no throwing, no crash
- `**` rules: leading `**/` matches in all directories; trailing `/**` matches everything inside; `a/**/b` matches zero or more intermediate directories; any other `**` behaves like `*`
- Matching is against the full relative path (anchored form) — anchoring/basename decisions live in the caller (IgnoreProcessor task), keeping this function pure
- Backslash escapes the following character (`\*` is a literal asterisk)

Use a recursive or iterative backtracking matcher over path segments (segment-wise for `**`, character-wise within a segment).

## Acceptance Criteria
- [ ] `*` never crosses `/`: `foo/*` matches `foo/bar`, not `foo/bar/baz`
- [ ] `**/foo` matches `foo`, `a/foo`, `a/b/foo`; `abc/**` matches everything under `abc/`; `a/**/b` matches `a/b`, `a/x/b`, `a/x/y/b`
- [ ] Character classes: ranges work; `[!...]` and `[^...]` both negate; each named POSIX class matches/rejects a representative character; unterminated `[` matches nothing without crashing
- [ ] `\*` matches only a literal `*`
- [ ] Matcher is iterative or bounded — no exponential blowup on pathological patterns like `a*a*a*a*b` vs long `aaaa...` input (test with a timeout-sized case)

## Tests
- [ ] New `Tests/FoundationModelsExtrasTests/WildmatchTests.swift` with a table-driven corpus of (pattern, path, expected) cases covering every bullet above, ported from git's own wildmatch test vectors where practical (t3070-wildmatch cases for the gitignore-relevant subset, including its `[^...]` and POSIX-class cases)
- [ ] `swift test --filter WildmatchTests` passes; full `swift test` stays green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.