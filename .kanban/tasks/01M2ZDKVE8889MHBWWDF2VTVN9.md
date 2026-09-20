---
position_column: todo
position_ordinal: '8280'
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