---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Import a session from another agent: origin, provenance and the directory port'
---
An imported session is a recorded root session with the origin `import` and the provenance of its source.

- [x] `SessionDirectoryOrigin.import` (raw value `import`).
- [x] `SessionImportProvenance`: agent, source id, source path, date of the last record, date of the import, count of skipped records.
- [x] `SessionSummary.importedFrom`, `nil` by default.
- [x] `SessionImportRequest` and `SessionDirectory.importSession(_:transcript:)`, with a default that throws the new `SessionDirectoryError.importUnsupported`.
- [x] `InMemorySessionDirectory.importSession`: idle, recorded, root, origin `import`, the provenance, the title with the next free number, no event; the test hook `importedTranscript(of:)`.
- [x] Tests: the codecs, the default, the in-memory import. #import