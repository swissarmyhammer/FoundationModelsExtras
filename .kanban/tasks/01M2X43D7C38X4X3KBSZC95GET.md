---
assignees:
- claude-code
depends_on:
- 01M2X30BQKPD2MKA5EJQPFYMZM
position_column: todo
position_ordinal: '8680'
title: 'FoundationModelsSkills: read skill files through DotfolderStack and delete its PathConfinement'
---
## What

Card ^qpfymzm moved the symbolic-link confinement rule into `FoundationModelsExtras` (`Sources/FoundationModelsExtras/PathConfinement.swift`), and each lookup of `DotfolderStack` applies it. `FoundationModelsSkills` still holds its own copy in `Sources/FoundationModelsSkills/Resources/PathConfinement.swift`, and `ReadResource`, `ListResource`, `RunScript`, `CatalogResolver` and `CatalogFileSource` call it.

The rule must live in one place. Make the Skills package get its files through the stack (`item(at:)`, `data(_:)`, `data(_:in:)`, `size(of:)`, `exists(_:)`, `tree(_:)`), and delete the Skills copy of `PathConfinement`.

## Acceptance Criteria

- [ ] `FoundationModelsSkills` holds no `PathConfinement` type.
- [ ] No resource operation of `FoundationModelsSkills` calls `FileManager` for a path check or a file read.
- [ ] The Skills tests that cover the confinement rule still pass.

#dotfolder-overlay #cross-repo