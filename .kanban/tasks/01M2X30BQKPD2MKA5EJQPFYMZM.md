---
comments:
- actor: claude-code
  id: 01m2x3m8mdwsy2xp1a18mbq6ne
  text: |-
    Picked up. Research:

    - `Sources/FoundationModelsExtras/DotfolderStack.swift` holds `DotfolderStack`, `Layer`, and a non-generic `Located` (url, layer). Lookups: `nearest`, `content`, `locate`, `enumerate`, `tree`, `childDirectories`, `layerDirectories`. Each applies the text check `isSafeRelativePath` only. No symbolic-link check exists.
    - Callers of `Located` in this package: `DotfolderStack.swift`, `Tests/.../DotfolderStackTests.swift` (`.url`, `.layer.source`), `Examples/ExtrasDemo/.../StackCommand.swift` (`entry.layer.source`). All of them keep to work with a generic `Located<Item>` that keeps `url` and `layer`.
    - `LayeredYAMLDocument.swift` and `DotfolderLoader.swift` call `locate` and `content` only. They do not change.
    - `FoundationModelsSkills/Sources/FoundationModelsSkills/Resources/PathConfinement.swift` holds the symbolic-link rule: resolve the symbolic links of the longest prefix of the candidate that exists, resolve the root, and accept only a candidate that is the root or under the root. The card says to move that rule here. This card cannot edit the Skills repository; the rule lands in this package as `Sources/FoundationModelsExtras/PathConfinement.swift`.
    - The existing test `aLayerRootThatIsASymbolicLinkIsWalked` expects the `url` of a located item to be the joined path (`<root>/review/SKILL.md`), not the resolved path. Thus the resolution serves the containment check only; `url` stays the joined path.
    - No `ARCHITECTURE.md` exists in the package.

    Design:
    - `Located<Item>` becomes a top-level generic struct (`url`, `layer`, `value`), `Sendable` when `Item` is.
    - `DotfolderStacking` protocol with `associatedtype Item: Sendable` and the functions from the card. `DotfolderStack` conforms with `Item == String`.
    - `enumerate` and `tree` give `Located<String>`, thus they read the text of each winning file. A file that is not valid UTF-8 is not in that view; `data(_:)` gives its bytes.
    - Test file: `Tests/FoundationModelsExtrasTests/DotfolderStackingTests.swift`, reusing `DotfolderStackTests.Fixture`.
  timestamp: 2026-09-19T15:12:47.245398+00:00
- actor: claude-code
  id: 01m2x43r7pqsq7wsjm9czh36c8
  text: |-
    Implementation landed, with `/tdd`.

    RED: `Tests/FoundationModelsExtrasTests/DotfolderStackingTests.swift` (new, 19 tests) did not compile: no `DotfolderStacking`, no `item`, `items`, `data`, `size`, `exists`, no `Located.value`.

    GREEN:
    - `Sources/FoundationModelsExtras/DotfolderStacking.swift` (new): top-level generic `Located<Item: Sendable>` (`url`, `layer`, `value`) and the `DotfolderStacking` protocol with the functions from the card.
    - `Sources/FoundationModelsExtras/PathConfinement.swift` (new): the symbolic-link confinement rule from the Skills package. Both the root and the candidate go through the same "resolve the symbolic links of the longest prefix that exists" step, so a missing layer root and a candidate under it compare in the same form.
    - `Sources/FoundationModelsExtras/DotfolderStack.swift`: the nested `Located` is gone; `enumerate` and `tree` give `Located<String>` (thus they read the text of each winning file); `item(at:)`, `items(in:named:)`, `data`, ranged `data`, `size(of:)`, `exists` added; each lookup routes through `Layer.confines(_:)`. Each single-path lookup routes through `winningCopy`, each byte lookup through `readingWinningCopy`, and `tree`/`enumerate` through `winningTexts(of:)`, so the override rule and the two path checks live in one place each.
    - `Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift`: the fixture got a `Data` overload of `write` and a `link` helper; the existing symbolic-link test uses the helper.

    Discoveries:
    - `Located.url` stays the joined path (`<root>/review/SKILL.md`), never the resolved path, because the existing test on a symbolic-link root expects that. The resolution serves the containment check only.
    - `tree` and `enumerate` decide the winner first and read the text after, so a winning copy that is not UTF-8 text leaves the view instead of letting a lower copy show through. That keeps them consistent with `item(at:)`.
    - The `no_magic_numbers` rule does not exempt a Swift Testing `@Suite`, so the byte ranges in the new tests are named `static let`s.
    - The deletion of the Skills copy of `PathConfinement` is a change in another repository. Follow-up task added on this board, depends on this card.

    Verification: `swift build --build-tests` gives 0 warnings; `swift test` gives 530 tests in 5 bundles, 0 failures.
  timestamp: 2026-09-19T15:21:14.742051+00:00
- actor: claude-code
  id: 01m2x43zxk53qjgq1f7k9yxs5y
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/DotfolderStacking.swift (new), Sources/FoundationModelsExtras/PathConfinement.swift (new), Sources/FoundationModelsExtras/DotfolderStack.swift, Tests/FoundationModelsExtrasTests/DotfolderStackingTests.swift (new), Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift; `swift build --build-tests` 0 warnings; `swift test` 530 tests, 0 failures
    - next: `/review` on ^qpfymzm; the Skills-side deletion of `PathConfinement` is task ^zc95get
  timestamp: 2026-09-19T15:21:22.611024+00:00
- actor: claude-code
  id: 01m2x478te8zprnmmzmb1e1zg2
  text: |-
    ### test — green
    - evidence: swift build --build-tests — 0 warnings, build complete; swift test — 301 tests, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-19T15:23:10.030110+00:00
depends_on:
- 01M2X2EMGFB08X9F0XV40N54DH
position_column: doing
position_ordinal: '80'
title: Make DotfolderStacking a generic interface, and the only file access
---
## What

Make the stack an **interface**, and make the interface generic in what one lookup gives back. The lower layers give content. A higher layer gives metadata with the content. Each layer has the same shape, thus a consumer composes the layers that it needs.

```
DotfolderStack                Item = String          find and read
StenciledDotfolderStack       Item = String          the same, rendered     (card ^cwm3mqt)
FrontmatterDocumentStack      Item = (metadata, content)                    (card ^9ta9smb)
```

This card gives the interface and the plain implementation.

1. **New protocol `DotfolderStacking`**, with `associatedtype Item`:
   - `var layers: [DotfolderStack.Layer] { get }`
   - `func item(at relativePath: String) -> Located<Item>?` — the winning copy, with the layer that gave it.
   - `func items(in subdirectory: String?, named fileName: String) -> [String: Located<Item>]` — for each child directory of the union that holds `fileName`, that file. The key is the name of the child directory. One call gives each `<id>/SKILL.md`.
   - `func tree(_ subdirectory: String?) -> [String: Located<Item>]` — the recursive combined view.
   - `func childDirectories(of subdirectory: String?) -> [String: [DotfolderStack.Layer]]`
   - `func layerDirectories(_ relativeDirectory: String?) -> [DotfolderStack.Layer]`
   - `func data(_ relativePath: String) -> Data?` — the bytes of the winning copy, for a file that is not text.
   - `func data(_ relativePath: String, in range: Range<Int>) -> Data?` — a part of the winning copy, for a consumer that pages a large file.
   - `func size(of relativePath: String) -> Int?`
   - `func exists(_ relativePath: String) -> Bool`
2. **`Located<Item>`** becomes generic: `url`, `layer` and `value: Item`. The layer is necessary at each level: a consumer needs it for the trust and for its own provenance.
3. **`DotfolderStack` conforms with `Item == String`**, and its behavior does not change. `nearest`, `locate`, `content` and `enumerate` stay as they are.
4. **The stack is the only thing that opens a file.** A consumer must never need `FileManager`. Thus each lookup resolves the symbolic links of the candidate and refuses a path that leaves its layer root, in addition to the text check of `isSafeRelativePath`. A path that escapes gives `nil`, `false` or an empty result, never a URL. `FoundationModelsSkills` holds this symbolic-link check today in `PathConfinement`; move that rule here.
5. A decorator gets its files from its base, thus only `DotfolderStack` touches the disk.

## Acceptance Criteria

- [x] `DotfolderStacking` is generic in `Item`, and `DotfolderStack` conforms with `Item == String` and no change of behavior.
- [x] `item(at:)` gives the copy of the highest layer, with the layer that gave it.
- [x] `items(in:named:)` gives one entry for each child directory that holds the named file, and it skips a directory that does not hold it.
- [x] `data(_:)`, the ranged form, `size(of:)` and `exists(_:)` all obey the combined view.
- [x] A path that resolves through a symbolic link to a location outside its layer root gives no result, for each lookup.
- [x] A file that is not valid UTF-8 gives `nil` from `item(at:)`, and its bytes from `data(_:)`.
- [x] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [x] `Tests/FoundationModelsExtrasTests/DotfolderStackingTests.swift` (new): two layers hold the same path; `item(at:)` gives the higher copy and names its layer.
- [x] Same file: `items(in: nil, named: "SKILL.md")` gives one entry for each child directory that holds the file.
- [x] Same file: a symbolic link that points outside the layer root gives no result from `item(at:)`, `data(_:)` and `exists(_:)`.
- [x] Same file: the ranged `data(_:in:)` gives the same bytes as the full read for that range.
- [x] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay #cross-repo