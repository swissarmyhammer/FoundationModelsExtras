---
assignees:
- claude-code
position_column: done
position_ordinal: ffa880
title: 'CatalogChangeNotice: the notice of a skills or agents catalog change'
---
Request from the FoundationModelsACPAgent session. The `skills` and `agents` tools list `- name: description` in their tool description, read one time when the tool is made. A catalog can reload during a session, and the tool description must stay byte-identical (transcript tests, prompt cache). So a change goes to the session as one notice.

## What
New file `Sources/FoundationModelsExtras/Hosting/CatalogChangeNotice.swift`:
- `CatalogKind`: open RawRepresentable string kind, like `WorkKind` (`.skills`, `.agents`). Codable as one string.
- `CatalogEntry { name, description }`: Sendable, Codable, Hashable. Never a body.
- `CatalogChangeNotice { kind, added, removed, changed }`: Sendable, Codable, Hashable.
  - `init?(kind:from old:to new:)` compares two catalogs by name. Returns nil when nothing changed. `added` and `changed` keep the new order, and `removed` keeps the old order. A duplicate name: the first entry wins.
  - `text`: what the model reads, for example ``Skills changed. New: `x`: does x. Changed: `z`: new z. Removed: `y`.``

## Tests (write them first, see them fail)
`Tests/FoundationModelsExtrasTests/CatalogChangeNoticeTests.swift`
- [ ] the same catalog gives nil (also in a new order)
- [ ] an added, a removed and a changed entry each go to their own list
- [ ] the order rules, and the first entry wins on a duplicate name
- [ ] the text of each section, and a section with no entries is left out
- [ ] a Codable round trip; CatalogKind encodes as one string #catalog-notice