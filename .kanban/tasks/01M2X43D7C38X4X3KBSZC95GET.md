---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2x53wtnqypp7wwd6cz8fpmz
  text: |-
    ### finish — skipped
    - reason: the work is in the FoundationModelsSkills repository, not in this tree. The finish loop works in the current tree only.
    - reason: Skills gets FoundationModelsExtras as a remote dependency on the `main` branch (`Package.swift` line 85). The stack API from ^qpfymzm (commits 41f7890, bd5c277, 922d0cd) is local and not pushed, thus Skills cannot build against it yet.
    - next: push the Extras `main` branch, then run `/finish ^zc95get` from the Skills repository.
  timestamp: 2026-09-19T15:38:48.021197+00:00
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