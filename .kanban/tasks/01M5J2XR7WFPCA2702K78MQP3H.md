---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5j88m9k1kg9be5ca5da63ed
  text: |-
    Implementation landed (TDD: FrontmatterDocumentSaveTests written first; RED was a compile failure on the missing save/rendered/FrontmatterDocumentSaveError/FileWriteCalls).

    Design:
    - `Sources/FoundationModelsExtras/FrontmatterDocument+Save.swift`: `extension FrontmatterDocument where Metadata: Encodable` with public `rendered()` and `save(to:)`, both `throws(FrontmatterDocumentSaveError)`; internal `save(to:calls:)` seam. Yams `YAMLEncoder` used only inside the file; no Yams type in public API. A private `FileReplacement` does: stat target for its mode (0644 when missing) -> `mkostemp(".<name>.XXXXXX", O_CLOEXEC)` in the target's folder -> fchmod -> one whole write -> fsync -> close -> `rename(2)`; any failure unlinks the temp file. The URL goes through `resolvingSymlinksInPath()` so a symlink at the path is kept and its target replaced.
    - nil metadata: body written alone; if the body itself would split as frontmatter, an empty `---\n---\n` block goes first so the body reads back exactly (note: a YAMLValue reader then sees frontmatter "" -> .null).
    - Reuse: extracted `JSONLFile.Calls` into shared internal `FileWriteCalls` (write/sync seam) with generic `writeWhole(_:to:failed:short:)`, `synchronize(_:failed:)`, `close(_:failed:)` taking the caller's error-case constructors. JSONLFile's private write/synchronize/close were deleted and now call these. Per ARCHITECTURE.md (no deprecated aliases), no `JSONLFile.Calls` typealias was kept; JSONLFileTests updated. The half-write fake moved to `Tests/.../HalfWriteCalls.swift`, shared by both suites. `FrontmatterDocument.fence` went from private to internal so the render writes the same fence the split reads. Uses SystemCall.retryingInterrupts for write/fsync; mkostemp is deliberately not retried (a failed run can alter the template).
    - Date round trip works because Yams Date.construct parses the timestamp regardless of the str tag YAMLValue.decoded re-tags it with.

    Not done / possible follow-ups: no directory fsync after rename (durability of the rename itself across power loss); YAMLValue is not Encodable, so a `FrontmatterDocument<YAMLValue>` from the default stack decode cannot be saved yet.

    Full `swift test`: 1554 + 410 + 131 + 44 + 40 + 26 tests passed, exit 0. Only warning in the log is the pre-existing SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle" build-graph warning, unrelated to these files. `swift format lint -s` clean on all new/changed files.
  timestamp: 2026-10-22T16:49:15.571353+00:00
- actor: claude-code
  id: 01m5j897ajpqd3kt2mwa0kz687
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/FrontmatterDocument+Save.swift (new), Sources/FoundationModelsExtras/FileWriteCalls.swift (new), Sources/FoundationModelsExtras/JSONLFile.swift, Sources/FoundationModelsExtras/FrontmatterDocument.swift, Tests/FoundationModelsExtrasTests/FrontmatterDocumentSaveTests.swift (new, 12 tests), Tests/FoundationModelsExtrasTests/HalfWriteCalls.swift (new), Tests/FoundationModelsExtrasTests/JSONLFileTests.swift; `swift test` exit 0; `swift format lint -s` clean
    - next: /review (not committed; task left in doing)
  timestamp: 2026-10-22T16:49:35.058921+00:00
- actor: claude-code
  id: 01m5j8bmnds80t5s1x0bn7awax
  text: |-
    ### test — green
    - evidence: swift test — 1554 tests in 160 suites passed, 0 failed, 0 skipped; swift format lint -s on 7 new/changed files: clean (0 findings). Only build warning is the SwiftPM bundle note "missing creator for mutated node ... mlx-swift_Cmlx.bundle", a dependency artifact outside our code.
    - next: review
  timestamp: 2026-10-22T16:50:54.253536+00:00
- actor: claude-code
  id: 01m5j8c23n1ehxs4kq7e4stpa5
  text: |-
    ### commit — changed
    - evidence: single local commit of green working tree (source, tests, kanban state); not pushed
    - next: review
  timestamp: 2026-10-22T16:51:08.021102+00:00
- actor: claude-code
  id: 01m5j8m37sy2vma54gay0azbwq
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (41c8ca2) — 0 findings, 0 confirmed, 1 refuted; 7 files reviewed, 2 .kanban files excluded by .reviewignore
    - next: send the landed sha 41c8ca2 to the Router session (foundationmodelsrouter-08)
  timestamp: 2026-10-22T16:55:31.321676+00:00
- actor: claude-code
  id: 01m5j8mayez9xa0a40f4fnbjxr
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files (FrontmatterDocument+Save.swift, FileWriteCalls.swift, JSONLFile.swift, FrontmatterDocument.swift, tests)
    - test: green — swift test, 1554 passed, 0 failed, 0 skipped
    - commit: 41c8ca2
    - review: clean — none
  timestamp: 2026-10-22T16:55:39.214450+00:00
position_column: done
position_ordinal: ffbf80
title: FrontmatterDocument save — write to a temp file and swap into place by default
---
Copied from FoundationModelsRouter card 01M5HS4GB26B9S1XGRGV6WCCQT (Router ^v6wccqt). Router session (foundationmodelsrouter-08) waits on it; send it the sha when landed.

## What
FoundationModelsExtras' `FrontmatterDocument` can split and read markdown with frontmatter, but has no save. Add one. User decision (2026-10-22): the save by default writes to a temp file in the same folder and swaps it into place, so a reader never sees a half-written file.
- Encode `Encodable` metadata as YAML frontmatter, with the internal Yams; no Yams type in the public API. Write the body after it unchanged.
- Reading back gives the same metadata and the exact same body.

## Subtasks
- [x] Render: metadata to `---` YAML `---`, then the body
- [x] `save(to:)`: temp file in the same directory, then an atomic replace
- [x] Failing tests first: round trip of metadata and body (multiline strings, dates, sets, nil); a body with `---` lines survives; no temp file left after the save; a failed save leaves the old file whole
- [x] `swift test` passes, zero warnings

#cross-repo #recording