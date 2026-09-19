---
depends_on:
- 01M2X2EMGFB08X9F0XV40N54DH
position_column: todo
position_ordinal: '8280'
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

- [ ] `DotfolderStacking` is generic in `Item`, and `DotfolderStack` conforms with `Item == String` and no change of behavior.
- [ ] `item(at:)` gives the copy of the highest layer, with the layer that gave it.
- [ ] `items(in:named:)` gives one entry for each child directory that holds the named file, and it skips a directory that does not hold it.
- [ ] `data(_:)`, the ranged form, `size(of:)` and `exists(_:)` all obey the combined view.
- [ ] A path that resolves through a symbolic link to a location outside its layer root gives no result, for each lookup.
- [ ] A file that is not valid UTF-8 gives `nil` from `item(at:)`, and its bytes from `data(_:)`.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/DotfolderStackingTests.swift` (new): two layers hold the same path; `item(at:)` gives the higher copy and names its layer.
- [ ] Same file: `items(in: nil, named: "SKILL.md")` gives one entry for each child directory that holds the file.
- [ ] Same file: a symbolic link that points outside the layer root gives no result from `item(at:)`, `data(_:)` and `exists(_:)`.
- [ ] Same file: the ranged `data(_:in:)` gives the same bytes as the full read for that range.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay #cross-repo