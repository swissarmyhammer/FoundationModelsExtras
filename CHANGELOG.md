# Changelog

Each change to the public API of this package is recorded here. The newest
change is at the top.

## Unreleased

### Added: `DotfolderStack` is directory-shaped, and `DotfolderStacking` is its interface

This change breaks the source of a consumer that names the type
`DotfolderStack.Located`. That type is now the generic `Located<Item>` at the
top level of the module, and `enumerate(_:suffix:)` gives
`[String: Located<String>]`. A consumer that reads `url` and `layer` from an
`enumerate` result, and does not name the type, compiles with no change.
`nearest`, `content`, `locate` and `enumerate` keep their signatures and their
results.

**Cause.** The stack was file-shaped and flat. It could find one file, and it
could list the files of one subdirectory by suffix, but it could not give a
view of a directory tree. A layer is a directory tree, and a consumer that
holds a skill at `<root>/<id>/SKILL.md` with scripts and references beside it
needs one combined view of the trees of all the layers.

**What changed.**

- The stack is directory-shaped. It gives one combined view of the directory
  trees of all the layers. The unit of override is the file: for a path
  relative to a layer root, the copy in the highest layer that holds that path
  wins. A directory is never replaced; it holds the union of the names of all
  the layers. The view is computed at the time of the call. The stack holds no
  cache, thus it needs no file watcher; a consumer that caches a result keeps
  its own watcher.
- `DotfolderStack.tree(_:)` is new. It gives the recursive combined view of a
  subdirectory, or of the layer roots when the argument is `nil`. The key is
  the file path relative to the subdirectory, at every depth.
- `DotfolderStack.childDirectories(of:)` is new. It gives each immediate child
  directory name of the union, with the layers that hold it, lowest precedence
  first.
- `DotfolderStack.layerDirectories(_:)` is new. It gives the layers that hold
  a directory, lowest precedence first, and an empty array when no layer holds
  it.
- `DotfolderStacking` is a new protocol, generic in `Item`, what one lookup
  gives back. It has `layers`, `item(at:)`, `items(in:named:)`, `tree(_:)`,
  `childDirectories(of:)`, `layerDirectories(_:)`, `data(_:)`, `data(_:in:)`,
  `size(of:)` and `exists(_:)`. `DotfolderStack` conforms with
  `Item == String`.
- `Located<Item>` is new, and it replaces `DotfolderStack.Located`. It holds
  `url`, `layer` and `value`, the value the stack made from the winning file.
- `DotfolderStack.item(at:)` is new. It gives the winning copy of a path with
  its layer and its text. `items(in:named:)` gives, for each child directory
  of the union that holds a named file, that file; one call gives each
  `<id>/SKILL.md` of a skill directory.
- `DotfolderStack.data(_:)`, `data(_:in:)`, `size(of:)` and `exists(_:)` are
  new. They give the bytes, a byte range, the size, and the presence of the
  winning copy, thus a consumer never needs `FileManager`.
- Each lookup resolves the symbolic links of its candidate and refuses a path
  that leaves its layer root, in addition to the text check that refuses an
  empty path, an absolute path, and a `..` component. This rule came from the
  `PathConfinement` type of `FoundationModelsSkills`.
- `enumerate(_:suffix:)` is now the top level of `tree(_:)`, filtered by
  suffix. Its result does not change.
