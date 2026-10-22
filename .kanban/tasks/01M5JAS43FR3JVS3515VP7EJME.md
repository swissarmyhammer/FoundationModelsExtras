---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'swift test: SwiftPM prints "missing creator for mutated node" for the mlx-swift_Cmlx bundle'
---
Found while working ^tmmhe2e. Every `swift test` build in /Users/wballard/github/swissarmyhammer/FoundationModelsExtras prints this build-system warning before the tests run:

`warning: missing creator for mutated node: ('/Users/wballard/github/swissarmyhammer/FoundationModelsExtras/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

It comes from the SwiftPM build graph for the mlx-swift `Cmlx` resource bundle, not from a source file. Find the cause (the package manifest, the mlx-swift dependency version, or the SwiftPM toolchain) and remove it so the build output has zero warnings.

## Subtasks
- [ ] Find why SwiftPM reports a missing creator for the `mlx-swift_Cmlx.bundle/Contents/MacOS` node
- [ ] Remove the cause so `swift test` prints zero warnings