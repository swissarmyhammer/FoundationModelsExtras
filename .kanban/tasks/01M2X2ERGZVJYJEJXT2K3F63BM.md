---
depends_on:
- 01M2X2EMGFB08X9F0XV40N54DH
position_column: todo
position_ordinal: '8180'
title: Put enumerate on the combined view, and correct the DotfolderStack documents
---
## What

After the combined view exists, the older lookups must use it, so that the stack holds one walk only, and so that the documents tell the true rule.

1. **One walk.** `enumerate(_:suffix:)` does its own loop over the layers. Write it on top of the combined view of the new `tree(_:)` (filter by suffix, keep the top level only). `nearest`, `content` and `locate` stay as they are: they are already correct for one path.
2. **Documents.** The type comment of `DotfolderStack` says that the stack "only locates files" and "never merges their contents". Correct this text. The stack does not merge the **contents** of a file, but it does give a combined **view** of the trees, and the unit of override is the file. Give the example of the layers in the comment.
3. **CHANGELOG.** Record the new functions, and record that the stack is now directory-shaped.
4. **No watcher.** State in the type comment that the stack holds no cache and thus needs no file watcher: each call reads the disk, and a consumer that caches keeps its own watcher.

## Acceptance Criteria

- [ ] `enumerate(_:suffix:)` has no loop of its own over the layers; it uses the combined view.
- [ ] The behavior of `enumerate(_:suffix:)` does not change: its tests pass without a change to them.
- [ ] The type comment states the file-level override rule, and gives the layer example.
- [ ] The type comment states that the stack holds no cache and no watcher.
- [ ] `CHANGELOG.md` has an entry for the new API.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift`: the tests of `enumerate` that are there now pass with no change.
- [ ] A new test shows that `enumerate` and `tree` agree on the same fixture, for the top level.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay