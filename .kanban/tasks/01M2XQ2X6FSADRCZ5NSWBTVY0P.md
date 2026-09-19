---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2xrrnysz5aqhhvqvwf15d7y
  text: |-
    Research and decision.

    A probe script over Foundation on this host shows:
    - `URL.standardizedFileURL` and `NSString.standardizingPath` remove the `/private` prefix only when the path exists. `/private/tmp/x` gives `/tmp/x` while `x` exists, and stays `/private/tmp/x` when it is gone.
    - `URL.resolvingSymlinksInPath()` also leaves a path that does not exist untouched. Thus it has the same dependency on the disk, and it does not satisfy the card.
    - `URL.standardized` is lexical, but it keeps a doubled `//`.
    - `TemporaryDirectory.make()` gives the canonical `/private/var/folders/...` form, thus a fixture repository URL is `file:///private/var/.../fixture.git`.

    Decision: the normalized `file://` URL is a pure function of the source text. The parser does only the lexical clean-up: it removes `.` components, it resolves `..` components against the components before them, it collapses repeated `/`, and it removes a trailing `/`. It does not read the disk, it does not resolve a symbolic link or a firmlink, and it does not remove a `/private` prefix. Thus the URL and the cache folder name are the same before and after the folder is deleted. The other option (`resolvingSymlinksInPath()` on both forms) is rejected because the probe shows it depends on the disk in the same way, and because the parser is documented as pure (`parts(ofNormalizedURL:)` reads no file).

    A consequence: two spellings of one folder (`/var/x` and `/private/var/x`) give two cache folders. That is accepted: the rule of `cacheFolderName` is that a changed URL never uses a stale cache.

    Plan: a RED test in `MarketplaceLocalSourceTests` that makes a `skills.git` folder under the canonical temporary directory, reads the normalized URL and the cache folder name, deletes the folder, reads them again, and expects the same values. Then replace `standardizedFileURL` in `MarketplaceLocation.localFolder(_:)` with a lexical clean-up, and write the rule in the doc comment of `normalizedURL`.
  timestamp: 2026-09-19T21:22:12.057913+00:00
- actor: claude-code
  id: 01m2xryz6cz663p3w8e7f63vp3
  text: |-
    Implementation landed.

    RED: `aFileGitSourceKeepsItsNormalizedURLAndCacheFolderNameAfterItsFolderIsRemoved` in `MarketplaceLocalSourceTests` failed as expected: `file:///var/.../skills.git` before the delete, `file:///private/var/.../skills.git` after it, and two cache folder names (`skills-75f11f1a` and `skills-adcb9e32`).

    GREEN: `MarketplaceLocation.localFolder(_:)` now builds the folder URL from `lexicallyCleanedPath(url.path)` and no longer calls `standardizedFileURL`. The new private `lexicallyCleanedPath(_:)` splits the path on `/`, drops `.` components, resolves `..` against the kept components, and joins the rest, thus it also collapses repeated `/` and removes a trailing `/`. The rule is written in the doc comment of `normalizedURL`. Two named constants, `currentFolderComponent` and `parentFolderComponent`, hold `.` and `..`.

    Regression rows in `MarketplaceSourceTests.validForms`: `file:///Users/me/../me/./skills//` gives the `/Users/me/skills` folder; `file:///private/var/skills.git` and `file:///private/var/./tools/../skills.git/` both give the git URL `file:///private/var/skills.git`. These rows passed before the change too, because the paths do not exist on the disk; they guard the hand-written clean-up.

    REFACTOR: the accumulator loop became a `filter` and a `reduce(into:)`, per the swift immutability rule.

    Full run: `swift test` gives 367 tests in 30 suites passed, zero warnings, exit 0. `swift format lint --strict` on the three changed files lists only pre-existing lines over 100 columns (the project has no `.swift-format` config); no new line is listed, and an unrelated reformat is out of scope.

    Consequence for other tests: `MarketplacePolicyTests` compute the exact pattern from the same `normalizedURL`, thus they keep passing; the fixture URL that a store hashes is now `file:///private/var/...` and no longer `file:///var/...`. A cache folder that an older build wrote for a `file://` source under `/private/var` while its folder existed is not found by the new build; that is accepted by the card's `cacheFolderName` rule (a changed URL never uses a stale cache).
  timestamp: 2026-09-19T21:25:38.124861+00:00
- actor: claude-code
  id: 01m2xrz121p5yhwgmet4sztggk
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/Marketplace/MarketplaceLocation.swift, Tests/MarketplaceTests/MarketplaceLocalSourceTests.swift, Tests/MarketplaceTests/MarketplaceSourceTests.swift; `swift test` 367 tests in 30 suites passed, 0 failures, 0 warnings
    - next: /review
  timestamp: 2026-09-19T21:25:40.033733+00:00
- actor: claude-code
  id: 01m2xs6205pptd4m9jxhn94ec2
  text: |-
    ### test — green
    - evidence: swift build --build-tests — 0 errors, 0 warnings; swift test — 367 tests in 30 suites passed, 0 failed, 0 skipped
    - next: send to review
  timestamp: 2026-09-19T21:29:30.373959+00:00
- actor: claude-code
  id: 01m2xs8k3hqx92e5bc3gyy4mz7
  text: |-
    ### commit — changed
    - evidence: a92483b fix(marketplace): keep the file:// URL the same when the folder is gone
    - next: run /review on the task.
  timestamp: 2026-09-19T21:30:53.425053+00:00
- actor: claude-code
  id: 01m2xscayk4g1dtgy12fq3w2fz
  text: |-
    ### review — clean
    - evidence: 0 findings (review sha HEAD~1..HEAD, commit a92483b; 3 files reviewed, 4 .kanban files skipped by .reviewignore)
    - next: none. The task is in done.
  timestamp: 2026-09-19T21:32:56.147888+00:00
- actor: claude-code
  id: 01m2xsctvzzctdpzeq97p2mvmx
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files
    - test: green — swift test, 367 passed in 30 suites, 0 failed, 0 skipped
    - commit: a92483b
    - review: clean — 0 findings, task moved to done
  timestamp: 2026-09-19T21:33:12.447193+00:00
position_column: done
position_ordinal: af80
title: 'MarketplaceLocation: the normalized URL of a file:// git source changes when its folder is gone'
---
## What

`MarketplaceLocation.localFolder(_:)` normalizes a `file://` URL with `URL(fileURLWithPath:isDirectory:).standardizedFileURL`. On macOS that call removes the `/private` prefix of a path only when the path exists on the disk. Thus a `file:///private/var/.../fixture.git` source normalizes to `file:///var/.../fixture.git` while the repository exists, and to `file:///private/var/.../fixture.git` after the repository is deleted.

`MarketplaceIdentity.cacheFolderName(key:normalizedURL:)` hashes the normalized URL. Thus a store over the same source string reads a different cache folder after the local repository is gone, and it does not find the snapshot that an earlier store installed. Card ^qtwjzx9 found this when its "unreachable URL keeps the last good snapshot" test deleted the fixture repository between two stores; that test now fails the remote through a transport double instead.

Decide and implement one rule: the normalized `file://` URL must not depend on whether the path exists. One option is to keep the path as the host wrote it, with only the lexical clean-up (`..`, `.`, trailing `/`). Another is `resolvingSymlinksInPath()` on both forms. Write the rule in the doc comment of `normalizedURL`.

## Acceptance Criteria

- [x] A `file://` git source under `/private/var` gives the same normalized URL and the same cache folder name before and after its folder is deleted.
- [x] `MarketplaceSourceTests` or `MarketplaceLocalSourceTests` holds a test for that rule.
- [x] `swift test` is green.

#marketplace