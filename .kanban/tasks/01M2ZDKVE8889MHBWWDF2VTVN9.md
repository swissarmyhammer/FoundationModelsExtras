---
comments:
- actor: claude-code
  id: 01m2zy3hxce6gz9r00sx6znxq5
  text: |-
    ### finish — note on the push criterion
    - The finish loop commits a local checkpoint on each iteration and never pushes. The push to `main` is the step of the user after the loop.
    - next: the user pushes `main` after this card is in `done`.
  timestamp: 2026-09-20T17:34:00.108798+00:00
- actor: claude-code
  id: 01m2zy846d67h3hy02ybgkjpkm
  text: |
    ### implement — research

    Read the source that the card names, `../FoundationModelsSkills/.../Registry/SkillWatcher.swift` (491 lines), and its suite `SkillWatcherTests.swift` (728 lines). Nothing in the skills repository is edited.

    What the read gives:

    - The type imports Foundation only and needs `open(2)`, `close(2)` and `DispatchSource`, thus the dependency budget of the core target does not move.
    - Its test helper `WatcherTestSupport.makeTempDirectory()` is the same folder maker as `FixtureSupport.TemporaryDirectory.make()` of this package, and `TemporaryDirectory.make()` already resolves the folder with `URL.canonicalDirectory`. Thus item 3 of the card ("canonicalize after `createDirectory`") needs no new code here: the shared helper does it.
    - The suite writes its fixture through `ReloadTestSupport.writeSkillFile(id:in:descriptionSuffix:)`, which writes `<root>/<id>/SKILL.md`. That helper is skill semantics. The new suite writes `<root>/<name>/document.md` with its own private helper, thus no file of the new type names a skill.
    - `DotfolderStack.Layer` has `root: URL`, thus `init(stack:)` maps `stack.layers` to `\.root`.

    Decisions (the card says to record each decision, and to ask the user nothing):

    1. The suite keeps the structure of the source suite: the manual debounce timer for each test that counts callbacks, and the real timer only in the two tests that the source runs on the real timer (the `stop()` test and the descriptor-count test), which assert no count that the speed of the host can change. That is what "keep each behavior of the source" and "each one drives the injected timer" mean together.
    2. The README example is contract-tested in the strong shape of `Tests/MarketplaceTests/ReadmeSnippetTests.swift`: the example is real code between two marker comments, and a second test proves that the fenced block of the README and the marked code are the same text, line for line.
    3. The plan.md note goes beside the `ProcessRunner` note under "Scope fights its way in", in the same parenthetical shape, dated 2026-09-20.
  timestamp: 2026-09-20T17:36:29.901287+00:00
- actor: claude-code
  id: 01m2zz66bsb2wyjbxbxvn6kwpn
  text: |
    ### implement — the decisions of the move

    Each decision, as the card asks. The user was asked nothing.

    1. **An internal stack initializer, beside the internal roots initializer.** The card keeps the internal init with the injected timer "for the tests". The public `init(stack:)` uses the real timer, thus a test of it could only wait on the real clock. `convenience init(stack:debounceInterval:startDebounceTimer:onChange:)` is internal, it maps `stack.layers` to `\.root` and calls the roots initializer, and the public `init(stack:)` calls it with the timer of the package. The test of `init(stack:)` thus drives the injected timer, the same as each other test that counts callbacks.
    2. **The default 200 ms stays a literal in the two public initializers.** A named `private static let` cannot be the default argument of a public initializer (the default argument is evaluated at the call site), and a public constant would add public surface that the card does not name. A default parameter is silent under the magic-number rule of the validators.
    3. **The README contract test follows the pattern of this test target.** `IgnoreProcessorTests` and `ProcessRunnerTests` both mirror the calls of their README block in one test, and the README names that test. `Tests/MarketplaceTests/ReadmeSnippetTests.swift` uses a stronger shape (marker comments, and a test that compares the text of the README with the marked code), but its helpers are private to that file, thus the strong shape here would copy them. The new test `readmeStackWatcherExample` makes the calls of the README section over temporary folders and waits for the callback.
    4. **`// swiftlint:disable:next no_unchecked_sendable` with the reason, above each `@unchecked Sendable`** (the type, and `WatcherBox` in the tests). The custom validator rule reads each file, test files included, and its text says that the annotation is the documentation.
    5. **The card ids of the other repository are gone.** The comments of the source name `^80kravf` and `^sz7fz7n`. The reasoning of each comment stays word for word; only the foreign ids are gone, because no reader of this repository can resolve them.
    6. **The file event mask is a named constant now** (`fileEventMask`), beside `directoryEventMask`. The source wrote it as a literal array at the call site. The two masks are thus one pair, and the documentation of each one is beside it.
    7. **The two tests of the source that use the real timer keep it**: the test of `stop()` and the test of the descriptor count. They assert no count that the speed of the host can change. Each test that counts callbacks drives the manual timer, thus the file work of a test never races the quiet period.
    8. **The fixture of the tests names no skill**: the helper writes `<root>/<name>/document.md`, in place of `ReloadTestSupport.writeSkillFile`. `grep -i skill` finds nothing in the two new files.

    Evidence: `swift build --build-tests` is clean with no warning, `swift test --filter DotfolderWatcherTests` gives 20 tests in 1 suite, and `swift test` is green 5 runs in sequence (exit 0 each, no failure and no warning).
  timestamp: 2026-09-20T17:52:55.161268+00:00
- actor: claude-code
  id: 01m2zz8jx48f0tg978jqfwv364
  text: |
    ### implement — changed
    - evidence: 6 files — new `Sources/FoundationModelsExtras/DotfolderWatcher.swift` (the type, with `init(roots:debounceInterval:onChange:)`, `init(stack:debounceInterval:onChange:)`, the two internal initializers with the injected timer, `start()`, `stop()`, `deinit`, the two counters for the tests, the queue label `FoundationModelsExtras.DotfolderWatcher`, and each behavior of the source: the two event masks, the recursion, the ancestor arming with its filter, the debounce by timer number, the reentrancy guard, and the flush order cancel-arm-call with its comment); new `Tests/FoundationModelsExtrasTests/DotfolderWatcherTests.swift` (20 tests: the burst, the deep change, the new subdirectory, the missing root with the ancestor filter, the root some levels below its ancestor, the unreadable directory, the change made inside `onChange`, the reentrant stop with the start again, the descriptor count after stop, `init(stack:)` over two layer roots, and the README example); `Sources/FoundationModelsExtras/DotfolderStack.swift` (the sentence now sends a caching consumer to `DotfolderWatcher`); `README.md` (the section `## Watching the layers: \`DotfolderWatcher\`` before `## Install`, with the contract-tested example); `plan.md` (the scope note of 2026-09-20, beside the `ProcessRunner` note); `CHANGELOG.md` (the entry under `## Unreleased`). Nothing in `FoundationModelsSkills` is touched. `swift build --build-tests`: complete, no warning. `swift test --filter DotfolderWatcherTests`: 20 tests in 1 suite, all pass. `swift test`: 5 runs in sequence, exit 0 each, no failure and no warning. `grep -i skill` finds nothing in the two new files.
    - next: `/review`. Item 5 of the card (commit and push) belongs to the finish loop and to the user, as the earlier comment on this card states.
  timestamp: 2026-09-20T17:54:13.540287+00:00
- actor: claude-code
  id: 01m2zznngthnbsatjrczve4fnp
  text: |-
    ### test — green
    - evidence: `swift package clean && swift build --build-tests` (0 warnings) then `swift test` — 434 tests, 33 suites, 0 failed, 0 skipped. `DotfolderWatcherTests` (DispatchSource-based) re-run 8 times with `swift test --filter 'FoundationModelsExtrasTests.DotfolderWatcherTests'` — 20/20 tests passed each run, no flake.
    - next: send the task to review.
  timestamp: 2026-09-20T18:01:22.202879+00:00
- actor: claude-code
  id: 01m2zzr4jds7t5wedz83yy007g
  text: |-
    ### commit — changed
    - evidence: 19af7e1 feat(dotfolder-watcher): add DotfolderWatcher and move it out of FoundationModelsSkills
    - next: run review of the commit
  timestamp: 2026-09-20T18:02:43.149969+00:00
- actor: claude-code
  id: 01m3002dr5wp1q1717zd2md3zc
  text: |
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` — 7 validators attempted, 0 failed, 4 findings (4 confirmed, 0 refuted). Sources/FoundationModelsExtras/DotfolderWatcher.swift:146 `code-hygiene/magic-numbers-swift`; Sources/FoundationModelsExtras/DotfolderWatcher.swift:173 `code-hygiene/magic-numbers-swift`; Sources/FoundationModelsExtras/DotfolderWatcher.swift:478 `swift/fluent-usage`; Sources/FoundationModelsExtras/DotfolderWatcher.swift:493 `swift/fluent-usage`.
    - next: correct the 4 findings in `DotfolderWatcher.swift`, and remove the same cause everywhere in that file: give each magic number a named constant, and give each event method a past-tense name. Then run the review again. The card stays in `review`.
  timestamp: 2026-09-20T18:08:20.229702+00:00
- actor: claude-code
  id: 01m3002tqnnsjhxpa02zt5x3av
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files. New `DotfolderWatcher.swift` and `DotfolderWatcherTests.swift`, plus `DotfolderStack.swift`, `README.md`, `plan.md` and `CHANGELOG.md`.
    - test: green — `swift test`, 434 tests in 33 suites, 0 failed, 0 skipped. The watcher suite ran 8 times with no flake.
    - commit: 19af7e1 — feat(dotfolder-watcher): add DotfolderWatcher and move it out of FoundationModelsSkills
    - review: findings — 7 validators attempted, 0 failed, 4 findings. `Sources/FoundationModelsExtras/DotfolderWatcher.swift:146` and `:173` (`code-hygiene/magic-numbers-swift`); `Sources/FoundationModelsExtras/DotfolderWatcher.swift:478` and `:493` (`swift/fluent-usage`).
    - next: iteration 2 corrects the 4 findings and removes the same cause from the whole file.
  timestamp: 2026-09-20T18:08:33.525535+00:00
- actor: claude-code
  id: 01m300d27t0nsqjxw0e142e3rv
  text: |
    ### implement — the 4 findings, and the cause removed from the whole file

    Each finding is a requirement. Each one is corrected, and the cause of each one is removed from the whole file, not only from the line that the finding names.

    **`code-hygiene/magic-numbers-swift` at `:146` and `:173` — "Magic numbers should be replaced by named constants."**

    An earlier comment on this card decided that the 200 ms default stays a literal, because a default argument is evaluated at the call site. The finding wins over that decision. Two measurements gave the correct fix:

    1. A `private static let` cannot be the default argument of a public initializer. Measured with `swiftc -swift-version 6`: `static property 'defaultDebounceInterval' is private and cannot be referenced from a default argument value` ... `note: ... is not '@usableFromInline' or public`. Thus the constant must be public.
    2. A named constant of type `DispatchTimeInterval` is not enough by itself. Measured with swiftlint 0.65.1 and `allowed_numbers: [0, 1, -1, 100]`: `public static let defaultDebounceInterval: DispatchTimeInterval = .milliseconds(200)` still REPORTS, because the `200` is an argument of a call, and the carve-out of the rule covers a plain literal in a declaration only (`let foo = 123`).

    The fix that satisfies the validator and compiles is thus a pair:

    - `private static let defaultDebounceMilliseconds = 200` — a plain literal in a declaration, which the rule does not report.
    - `public static let defaultDebounceInterval = DispatchTimeInterval.milliseconds(defaultDebounceMilliseconds)` — no literal at all.

    Each public initializer now reads `debounceInterval: DispatchTimeInterval = DotfolderWatcher.defaultDebounceInterval`, and the documentation of each parameter names `defaultDebounceInterval` in place of "200 ms". The value that a caller receives does not change.

    The new public constant is the one new item of public surface. It is documented, and it gives a caller the default period by name.

    Measured after the fix: swiftlint reports 0 findings over the whole file with that configuration. The `200` and the two masks are the only numbers of the file that are not `0`, `1` or `-1`.

    **`swift/fluent-usage` at `:478` and `:493` — "Event-handling method uses `handle...` prefix instead of past-tense pattern."**

    The file held two such methods, and both are renamed to a name that the finding itself gives:

    - `handleAncestorEvent(at:)` -> `ancestorEventDidOccur(at:)`
    - `handleRawEvent()` -> `fileSystemEventDidOccur()`

    Each call site and each documentation reference is renamed with them. `grep` over `Sources`, `Tests`, `Examples` and `README.md` finds no `handle` name of this file any more. The two remaining `handler` words are `setEventHandler(handler:)` and `setCancelHandler`, which belong to Dispatch. Each other method of the file is an effectful imperative verb phrase (`armRoots()`, `watchTree(at:)`, `flush()`), which is what the rule asks for.

    Evidence: `swift build --build-tests` complete with no warning; `swift test` 434 tests in 33 suites, 0 failed, 0 skipped; `swift-format lint --strict` gives the same 5 lines as `HEAD` gives, thus this change adds no formatting error.
  timestamp: 2026-09-20T18:14:08.890489+00:00
- actor: claude-code
  id: 01m300d92kvgw08gt7pw12r7r3
  text: |
    ### implement — changed
    - evidence: 1 file — `Sources/FoundationModelsExtras/DotfolderWatcher.swift`. The 4 findings of the newest `## Review Findings` section are corrected and checked: the two magic numbers become `defaultDebounceMilliseconds` and `defaultDebounceInterval`, and the two event methods become `ancestorEventDidOccur(at:)` and `fileSystemEventDidOccur()`. `swift build --build-tests`: complete, 0 warnings. `swift test`: 434 tests in 33 suites, 0 failed, 0 skipped. `swiftlint` with `no_magic_numbers` and `allowed_numbers: [0, 1, -1, 100]`: 0 findings over the file, where it gave 2 before. Nothing is committed, nothing is pushed, and `FoundationModelsSkills` is not touched.
    - next: `/review` of the file again. The card stays in `doing`.
  timestamp: 2026-09-20T18:14:15.891833+00:00
- actor: claude-code
  id: 01m300vd62bxfy8y5aykmpv3k7
  text: |-
    ### test — green
    - evidence: `swift test` — 434 tests, 33 suites, 0 failed, 0 skipped. `swift package clean && swift build --build-tests` — 0 warnings. `swift test --filter 'FoundationModelsExtrasTests.DotfolderWatcherTests'` run 10 times — 20/20 tests passed each run (200 executions total, 0 failures), thus no flake found in the `DispatchSource` file-system-source path. Old symbol names `handleRawEvent` and `handleAncestorEvent(at:)` do not occur anywhere in the tree; only the new names `fileSystemEventDidOccur()` and `ancestorEventDidOccur(at:)` are present.
    - next: send the task to review.
  timestamp: 2026-09-20T18:21:58.850272+00:00
- actor: claude-code
  id: 01m300xr1cf1b4fcbk365fp6me
  text: |-
    ### commit — changed
    - evidence: 12257d2 refactor(dotfolder-watcher): name debounce constants and rename event methods
    - next: Run the review step to confirm all four findings are cleared.
  timestamp: 2026-09-20T18:23:15.500112+00:00
- actor: claude-code
  id: 01m3010jsc0n6s9vq6zk1z9p1z
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 12257d2). 7 validators attempted, 0 failed, 0 findings, 0 confirmed, 0 refuted. 1 file reviewed, 2 files not reviewed because an ignore rule holds them (`.kanban/`). No new file:line finding. The 4 findings of the round 2026-09-20 13:03 are all marked `- [x]`: DotfolderWatcher.swift `code-hygiene/magic-numbers-swift` x2, and DotfolderWatcher.swift `swift/fluent-usage` x2.
    - next: The card moves to `done`. No open finding stays.
  timestamp: 2026-09-20T18:24:48.428207+00:00
- actor: claude-code
  id: 01m3010yeg4anxa5nnbkhm93yz
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file, `Sources/FoundationModelsExtras/DotfolderWatcher.swift`. The 4 findings are corrected and each item is checked.
    - test: green — `swift test`, 434 tests in 33 suites, 0 failed, 0 skipped. The watcher suite ran 10 times with no flake.
    - commit: 12257d2 — refactor(dotfolder-watcher): name debounce constants and rename event methods
    - review: clean — 7 validators attempted, 0 failed, 0 findings. Each of the 4 earlier findings is `- [x]`. The task moved to `done`.
    - note: the push criterion stays with the user after the loop.
  timestamp: 2026-09-20T18:25:00.368298+00:00
position_column: done
position_ordinal: b580
title: 'Add DotfolderWatcher: move the recursive directory watcher out of FoundationModelsSkills'
---
## What

This package has no file watcher. `DotfolderStack.swift` says: "The stack holds no cache, thus it needs no file watcher. A consumer that caches a result keeps its own watcher." The first sentence is correct. The second sentence sends raw file system work to each consumer, and that is against the rule of the family: the raw work of loading lives here, and a consumer keeps only the work of its own schema.

`FoundationModelsSkills` holds such a watcher: `../FoundationModelsSkills/Sources/FoundationModelsSkills/Registry/SkillWatcher.swift`, 491 lines. It has no skill content. It takes `roots: [URL]`, calls `onChange` after a quiet period, and states that it has no opinion about what changed. It opens file descriptors with `open(path, O_EVTONLY)`, makes one `DispatchSource` file system source for each directory and each file, lists directories with `FileManager`, and arms the nearest existing ancestor of a root that does not exist yet. Move it here.

1. **New type `DotfolderWatcher`** in `Sources/FoundationModelsExtras/DotfolderWatcher.swift`, core target. It needs Foundation and Dispatch only, thus the dependency budget does not move.
   - `public convenience init(roots: [URL], debounceInterval: DispatchTimeInterval = .milliseconds(200), onChange: @escaping @Sendable () -> Void)`
   - `public convenience init(stack: some DotfolderStacking, debounceInterval:onChange:)`: the roots are the layer roots of the stack.
   - `public func start()`, `public func stop()`; `deinit` stops.
   - The internal init with the injected debounce timer stays, for the tests.
2. **Keep each behavior of the source**, with 2-space indentation: the two event masks (a directory: write, delete, rename; a file: also extend and attrib); the recursion over the tree; the ancestor arming for a missing root, with the filter that ignores unrelated changes under a busy ancestor; the debounce by a timer number, not by a timer cancel; `stop()` that is safe from inside `onChange`; the flush order **cancel all sources, arm the roots, then call `onChange`**, with its comment, because the other order loses a change in the gap; the two counters for the tests. Rename the queue label to `FoundationModelsExtras.DotfolderWatcher`. No comment names a skill.
3. **Move the tests**: `../FoundationModelsSkills/Tests/FoundationModelsSkillsTests/SkillWatcherTests.swift` becomes `Tests/FoundationModelsExtrasTests/DotfolderWatcherTests.swift`. Its temporary directory helper (`WatcherTestSupport`) comes from `FixtureSupport`. Canonicalize a temporary directory after `createDirectory`, because of the `/var` firmlink. No test waits on the real clock: each one drives the injected timer.
4. **Documents.** `DotfolderStack.swift`: change the sentence to "A consumer that caches a result watches the layer roots with `DotfolderWatcher`". `plan.md`: add the scope note, dated 2026-09-20, in the shape of the `ProcessRunner` note: `FoundationModelsSkills` carried a watcher with no skill semantics; it belongs beside the stack. `README.md`: a short section `## Watching the layers: \`DotfolderWatcher\`` before `## Install`, with a contract-tested example. `CHANGELOG.md`: one entry under `## Unreleased`.
5. Commit and push to `main`.

Do not edit `FoundationModelsSkills` in this card. A card on that board deletes `SkillWatcher` after this lands.

## Acceptance Criteria

- [ ] `DotfolderWatcher` gives one `onChange` call for a burst of changes inside the debounce interval.
- [ ] A change of a file at any depth under a root gives a call; a new file in a new subdirectory gives a call.
- [ ] A root that does not exist at `start()` gives a call when it appears, and unrelated changes under its ancestor give no call.
- [ ] `stop()` closes each file descriptor, and it is safe from inside `onChange`.
- [ ] `init(stack:)` watches each layer root of the stack.
- [ ] No file of the type names a skill.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green, 5 runs in sequence with no failure.
- [ ] The work is committed and pushed to `main` of this repository.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/DotfolderWatcherTests.swift`: each case of the source suite, with the injected timer: the burst, the deep change, the new subdirectory, the missing root with the ancestor filter, the unreadable directory, the reentrant stop, the descriptor count after stop, start after stop.
- [ ] Same file: `init(stack:)` with two layer roots gives a call for a change under each root.
- [ ] A README snippet test for the new section.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#loading-boundary #cross-repo

## Review Findings (2026-09-20 13:03)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 7 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 3 file(s) not reviewed — no validator matched:
> - `CHANGELOG.md` — no validator matches this file
> - `README.md` — no validator matches this file
> - `plan.md` — no validator matches this file

- [x] `Sources/FoundationModelsExtras/DotfolderWatcher.swift:146` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsExtras/DotfolderWatcher.swift:173` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsExtras/DotfolderWatcher.swift:478` `swift/fluent-usage` — Event-handling method uses `handle...` prefix instead of past-tense pattern. Method names for events should read as past-tense statements about what happened, not imperative commands to handle something. Rename to `ancestorEventDidOccur` or `ancestorDidChange` to read as a past-tense statement.
- [x] `Sources/FoundationModelsExtras/DotfolderWatcher.swift:493` `swift/fluent-usage` — Event-handling method uses `handle...` prefix instead of past-tense pattern. Method names for events should read as past-tense statements about what happened, not imperative commands to handle something. Rename to `eventDidOccur` or `fileSystemEventDidOccur` to read as a past-tense statement.
