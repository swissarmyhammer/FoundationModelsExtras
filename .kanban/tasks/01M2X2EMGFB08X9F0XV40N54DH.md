---
comments:
- actor: claude-code
  id: 01m2x31j78bvr9wrhknjngmjnd
  text: |-
    Research and implementation notes.

    - The three view functions share one private helper, `layerDirectoryURLs(_:)`. It gives one `(layer, url)` pair for each layer, or `nil` when the path is not safe. `nil` for the path means the layer root. All three functions apply the same `isSafeRelativePath` check through it.
    - The walk uses `FileManager.subpathsOfDirectory(atPath:)`, a path API. The test `aLayerRootThatIsASymbolicLinkIsWalked` shows that a symbolic link root is followed, and that the returned URL goes through the link, not through the target.
    - `fileExists(atPath:isDirectory:)` splits files from directories. A symbolic link to a directory counts as a directory.
    - Higher layers win through `Dictionary(_, uniquingKeysWith:)`. The layers iterate lowest first, so the last pair for a key is the highest layer. `childDirectories(of:)` merges with `+`, so the layer arrays are lowest first.
    - The type doc comment and the `isSafeRelativePath` doc comment name the entry points. Both lists now include `tree`, `childDirectories`, and `layerDirectories`. The larger document correction is the scope of task 01M2X2ERGZVJYJEJXT2K3F63BM.
    - The test fixture got `makeStack(defaultsDirectory:environment:)` and `writeReviewTree()`. The new tests use them. The two older tests that build a stack by hand were not changed.
    - The validator rules file has 12,098 lines. I read the language-agnostic rules and the Swift prompt rules in full, and the head of each Swift tool rule. I did not read the Go, Dart, Python, Rust, and TypeScript tool rules.
    - `swift format lint -s` reported two lines over 100 columns. Both are wrapped. The repo has no `.swift-format`, `.swiftformat`, or `.swiftlint.yml`, so the tool defaults apply.
  timestamp: 2026-09-19T15:02:34.472992+00:00
- actor: claude-code
  id: 01m2x31qvvt9yqf6kysj1w4q21
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsExtras/DotfolderStack.swift (adds `tree(_:)`, `childDirectories(of:)`, `layerDirectories(_:)` and four private helpers; updates two doc lists), Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift (13 new tests, two fixture helpers, one shared `unsafePaths` constant). TDD: the 13 tests failed first with `has no member 'tree'` and the like, then passed. `swift build --build-tests`: 0 warnings. `swift test`: 284 tests in 25 suites passed, 0 failures. `swift format lint -s` on the two files: clean.
    - next: `/review` — the task stays in `doing` for the review gate.
  timestamp: 2026-09-19T15:02:40.251072+00:00
- actor: claude-code
  id: 01m2x36tpg5e2cppq0ejnjdf0t
  text: |-
    ### test — green
    - evidence: swift build --build-tests (clean, 0 warnings) then swift test — 284 passed, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-19T15:05:26.992251+00:00
position_column: doing
position_ordinal: '80'
title: 'Make DotfolderStack directory-shaped: one combined view of the layer trees'
---
## What

`DotfolderStack` (`Sources/FoundationModelsExtras/DotfolderStack.swift`) is file-shaped and flat. It can find one file (`nearest`, `content`, `locate`) and it can list the files of one subdirectory by suffix (`enumerate`). It cannot give a view of a directory tree.

This is a defect. A layer is a directory tree, and the stack must give **one combined view** of the trees of all the layers:

1. The unit of override is the **file**, not the directory. For a path relative to a layer root, the copy in the highest layer that holds that path wins. Each lower copy is hidden.
2. A directory is never replaced. A directory in the view holds the union of the names of all the layers.
3. A layer that holds no copy of a path adds nothing. A missing layer root is not an error.
4. The view is computed at the time of the call. The stack holds no cache, thus it needs no watcher.

Example, with `defaults < user < project`:

```
defaults/review/SKILL.md            user/review/SKILL.md        project/review/references/house-style.md
defaults/review/references/rules.md user/review/scripts/lint.sh
defaults/review/scripts/lint.sh
defaults/review/scripts/report.sh
```

The view of `review/` gives: `SKILL.md` from user, `scripts/lint.sh` from user, `scripts/report.sh` from defaults, `references/rules.md` from defaults, `references/house-style.md` from project.

## The new API

Add these to `DotfolderStack`. Keep `nearest`, `content`, `locate` and `enumerate` as they are.

- `public func tree(_ subdirectory: String? = nil) -> [String: Located]` — the recursive combined view. The key is the file path relative to `subdirectory`. The value is the winning file and its layer.
- `public func childDirectories(of subdirectory: String? = nil) -> [String: [Layer]]` — for each immediate child directory name in the union, the layers that hold it, lowest precedence first.
- `public func layerDirectories(_ relativeDirectory: String? = nil) -> [Layer]` — the layers that hold `relativeDirectory`, lowest precedence first. A consumer needs this to know which layer gave a file, for example before it runs a script.

Rules for all three:

- `nil` means the layer root itself. A consumer that keeps its items directly under the root (for example a skill directory at `<root>/<id>/`) needs this form.
- A given path uses the existing `isSafeRelativePath` check. An unsafe path gives an empty result.
- A root that does not exist, or that cannot be read, contributes nothing.
- The walk goes through the **path** of the root, not the URL, because a layer root can be a symbolic link to a directory.
- No name is skipped in the walk (`.git` and `node_modules` are the policy of the consumer, not of the stack).

## Acceptance Criteria

- [x] `tree(_:)` gives the union of the file paths of all the layers, and each path maps to the copy of the highest layer that holds it.
- [x] `childDirectories(of:)` gives each child directory name of the union, with the layers that hold it, lowest first.
- [x] `layerDirectories(_:)` gives the layers that hold a directory, lowest first, and an empty array when no layer holds it.
- [x] A layer root that is a symbolic link to a directory is walked.
- [x] An unsafe path (empty, absolute, or with `..`) gives an empty result for each of the three functions.
- [x] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [x] `Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift`: three layers hold the same subdirectory; `tree` gives the union, and each file comes from the correct layer.
- [x] Same file: a file that only the lowest layer holds stays in the view when a higher layer holds other files of the same directory.
- [x] Same file: `childDirectories(of:)` gives a name that only one layer holds, and gives both layers for a name that two layers hold, lowest first.
- [x] Same file: `layerDirectories(_:)` gives the layers lowest first, and gives an empty array for a directory that no layer holds.
- [x] Same file: a layer root that is a symbolic link is walked; a root that does not exist adds nothing.
- [x] Same file: an empty path, an absolute path and a `..` path each give an empty result.
- [x] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay #cross-repo