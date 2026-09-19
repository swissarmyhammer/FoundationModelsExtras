---
comments:
- actor: claude-code
  id: 01m2xsj74050v2xkj79fec4k6j
  text: |-
    Research done.

    - `tree(_:)` in `DotfolderStack.swift` makes the walk: `layerDirectoryURLs(_:)` gives one directory for each layer, `filePaths(under:in:)` gives the confined file paths, and `winningTexts(of:)` applies the override rule (`uniquingKeysWith { _, higher in higher }`) and then the UTF-8 rule (`locatedText`).
    - The plan: a private `winningCopies(in:)` makes the walk and applies the override rule. `urls(_:)` maps each copy to `Located<URL>`. `tree(_:)` routes the same copies through `winningTexts(of:)`, which keeps the UTF-8 rule alone.
    - `DotfolderStacking` has three conformers in this package: `DotfolderStack`, `FrontmatterDocumentStack`, `StenciledDotfolderStack`. No test fake conforms to it, thus the new requirement breaks no fake.
    - The two layered stacks forward `urls(_:)` to `base`, the same as `data(_:)`, `size(of:)` and `exists(_:)`.
    - Review rules read: the Swift prompt rules (access control, casing, doc parameter naming, idioms, immutability, optionals, preconditions), the duplication, reuse, completeness and test-integrity rules in full, and the head of each Swift tool rule (dead code, disallowed constructs, function length, idioms, magic numbers, missing docs). The rules for Dart, Go, Python, Rust and TypeScript do not apply to Swift files and were not read.
    - No `ARCHITECTURE.md` exists at the package root.
  timestamp: 2026-09-19T21:36:08.832574+00:00
- actor: claude-code
  id: 01m2xsy6ckwavgrp95bz80p3tt
  text: |-
    Implementation landed, with TDD (RED: `value of type 'DotfolderStack' has no member 'urls'` in the test build; GREEN: 113 tests in the four stack suites, then 375 tests in 30 suites with `swift test`).

    Decisions:

    - `winningCopies(in:)` is a new private helper on `DotfolderStack`. It makes the walk (`layerDirectoryURLs`, `filePaths(under:in:)`) and applies the override rule (`uniquingKeysWith { _, higher in higher }`), and it opens no file. `tree(_:)` and `urls(_:)` both route through it.
    - `winningTexts(of:)` now takes the `[String: Copy]` dictionary that `winningCopies(in:)` gives, and applies the UTF-8 rule alone (`compactMapValues(locatedText)`), as the card asks. `tree(_:)` is its one caller.
    - `urls(_:)` gives `Located<URL>` with the URL as both `url` and `value`. This is the shape the card names, and it keeps `Located` as the one result type of the interface.
    - The protocol gains `urls(_:)` beside `tree(_:)`. The doc of `tree(_:)` on the protocol and on `DotfolderStack` says it holds the text files only; the doc of `urls(_:)` says it holds every file and opens no file.
    - `FrontmatterDocumentStack.urls(_:)` and `StenciledDotfolderStack.urls(_:)` forward to `base.urls(subdirectory)`, the same as `data`, `size(of:)` and `exists`. The type docs of both list the URL view with the byte lookups as unchanged pass-throughs.
    - Tests: the "opens no file" criterion is proved with a file whose POSIX permissions are `0`: `urls()` holds it, `tree()` and `data(_:)` do not. The test would not hold as root, because root can read such a file; the CI runner is not root.
    - `binaryBytes` moved from a private constant of `DotfolderStackingTests` to `DotfolderStackTests.Fixture.binaryBytes`, because `FrontmatterDocumentStackTests` now needs the same bytes. One definition, three consumers.
    - The `StenciledDotfolderStack` test uses a file that fails to render, not a binary file: that is the one case where the stenciled `tree(_:)` drops an entry, and it proves that `urls(_:)` keeps it.
    - `swift format lint --strict` on the eight changed files gives no finding. No `.swift-format` file exists in the package, thus the toolchain defaults apply.
  timestamp: 2026-09-19T21:42:41.299052+00:00
- actor: claude-code
  id: 01m2xsza7vtdges6n9bbcyt2jf
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsExtras/DotfolderStack.swift, Sources/FoundationModelsExtras/DotfolderStacking.swift, Sources/FoundationModelsExtras/FrontmatterDocumentStack.swift, Sources/FoundationModelsExtras/StenciledDotfolderStack.swift, Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift, Tests/FoundationModelsExtrasTests/DotfolderStackingTests.swift, Tests/FoundationModelsExtrasTests/FrontmatterDocumentStackTests.swift, Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift. `swift build --build-tests` 0 warnings; `swift test` 375 tests in 30 suites passed, 0 failures, 0 skipped; `swift format lint --strict` on the 8 files gives no finding.
    - next: `/review`. Not committed, not pushed, as the caller asked.
  timestamp: 2026-09-19T21:43:18.011745+00:00
- actor: claude-code
  id: 01m2xt5eae14deevxrp7jyndmx
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` — 0 warnings; `swift test` — 375 tests, 30 suites, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-19T21:46:38.798249+00:00
position_column: doing
position_ordinal: '80'
title: Give the dotfolder stack a view of the winning URLs, with no text read
---
## What

`DotfolderStack.tree(_:)` gives `[String: Located<String>]`: the text of the
winning copy. It builds that dictionary with `winningTexts(of:)`, which calls
`locatedText`, which reads the file with `String(contentsOf:encoding:.utf8)`. A
copy that the reader cannot decode is dropped. Thus a file whose bytes are not
UTF-8 text -- for example a PNG under `assets/`, or a compiled helper under
`scripts/` -- is not in the view at all.

A consumer that lists the files of a directory tree must show such a file.
`SkillOverlay.entries()` of `FoundationModelsSkills` is one: its `list resource`
operation must give a PNG, with the kind `asset` and the size in bytes. That
operation gives no text, thus the text is of no use to it.

The rule of the family says that a consumer walks no directory of its own and
opens no file of its own; only `DotfolderStack` touches the disk. Thus the
consumer cannot make the list itself, and the stack must give a view that holds
every file.

## The work

Add a view that gives the URL of the winning copy and reads no text:

```swift
func urls(_ subdirectory: String? = nil) -> [String: Located<URL>]
```

1. `DotfolderStacking`: add the requirement, beside `tree(_:)`.
2. `DotfolderStack`: make the same walk that `tree(_:)` makes --
   `layerDirectoryURLs(_:)`, `filePaths(under:in:)`, and the same
   `uniquingKeysWith` override rule -- but put the URL of the winning copy in
   the value. No file is opened. `tree(_:)` then becomes the text view over the
   same walk, and `winningTexts(of:)` keeps the UTF-8 rule for the text view
   alone.
3. `FrontmatterDocumentStack` and `StenciledDotfolderStack`: forward `urls(_:)`
   to the base stack, the way `data(_:)`, `size(of:)` and `exists(_:)` already
   do. Each of the two makes its item from text, thus neither one filters the
   URL view.
4. State the difference in the two doc comments: `tree(_:)` holds the text files
   only, and `urls(_:)` holds every file.

## Acceptance Criteria

- [x] `urls(_:)` gives each file of the union of the layers, at every depth,
      whether or not its bytes are UTF-8 text.
- [x] `urls(_:)` applies the same override rule as `tree(_:)`: the copy of the
      highest layer that holds a path wins, and a directory is never replaced.
- [x] `urls(_:)` refuses the same unsafe subdirectory paths as `tree(_:)`, and
      it drops a file that resolves through a symbolic link to a location
      outside its layer root.
- [x] `urls(_:)` opens no file.
- [x] `FrontmatterDocumentStack.urls(_:)` and `StenciledDotfolderStack.urls(_:)`
      give what the base stack gives.
- [x] Tests: a file of bytes that are not UTF-8 is in `urls(_:)` and is not in
      `tree(_:)`; a lower layer only holds a path and that path is in
      `urls(_:)`; a higher layer wins a shared path.
- [x] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Who needs this

Card `^txjvhav` of `FoundationModelsSkills` ("SkillOverlay.entries leaves out a
file that is not UTF-8 text") is stopped until this card lands and
`FoundationModelsSkills` pins the new revision of `main`. That card blocks
`^g9jt4sq` ("list resource and read resource over the combined view") of the
same board. #dotfolder-overlay #cross-repo