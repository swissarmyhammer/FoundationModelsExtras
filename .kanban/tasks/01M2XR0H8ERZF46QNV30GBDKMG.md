---
position_column: todo
position_ordinal: '8780'
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

- [ ] `urls(_:)` gives each file of the union of the layers, at every depth,
      whether or not its bytes are UTF-8 text.
- [ ] `urls(_:)` applies the same override rule as `tree(_:)`: the copy of the
      highest layer that holds a path wins, and a directory is never replaced.
- [ ] `urls(_:)` refuses the same unsafe subdirectory paths as `tree(_:)`, and
      it drops a file that resolves through a symbolic link to a location
      outside its layer root.
- [ ] `urls(_:)` opens no file.
- [ ] `FrontmatterDocumentStack.urls(_:)` and `StenciledDotfolderStack.urls(_:)`
      give what the base stack gives.
- [ ] Tests: a file of bytes that are not UTF-8 is in `urls(_:)` and is not in
      `tree(_:)`; a lower layer only holds a path and that path is in
      `urls(_:)`; a higher layer wins a shared path.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Who needs this

Card `^txjvhav` of `FoundationModelsSkills` ("SkillOverlay.entries leaves out a
file that is not UTF-8 text") is stopped until this card lands and
`FoundationModelsSkills` pins the new revision of `main`. That card blocks
`^g9jt4sq` ("list resource and read resource over the combined view") of the
same board. #dotfolder-overlay #cross-repo