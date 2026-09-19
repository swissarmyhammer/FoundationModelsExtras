---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: Make the top-level private types of CatalogResolver.swift and SnapshotWriter.swift fileprivate
---
## What

The `swift/access-control` rule says: `fileprivate` is required when a sibling type in the same file reads a type; `private` reaches only the same declaration and same-file extensions of that exact type. The review of card ^qtwjzx9 found this cause on `Preparation` in `Sources/Marketplace/MarketplaceStore.swift`, and that card corrected only its own file. The same cause is in two other files of the target:

- `Sources/Marketplace/CatalogResolver.swift`: `private struct Diagnosed<Value>` and `private struct CatalogReader`
- `Sources/Marketplace/SnapshotWriter.swift`: `private struct SnapshotRun`

For each type:

1. Trace the reader. A sibling type in the same file reads it, thus it becomes `fileprivate struct`. A type that no sibling reads is dead code, and it goes away.
2. Add the sentence of the file convention to its doc comment, as `MarketplaceStore.swift` does: "The <reader> reads it, thus it is `fileprivate` and not `private`."

Do not change any other access level. Do not change behavior.

## Acceptance Criteria

- [ ] No top-level type under `Sources/Marketplace` is `private`.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `swift test` — all tests pass, 0 failures.

#marketplace