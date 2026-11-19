---
assignees:
- claude-code
position_column: done
position_ordinal: fffe80
title: The recap of a session on SessionSummary
---
Add `SessionSummary.recap: String?` and `recapAt: Date?`, with the default `nil` in the initializer. No new event: a new recap goes out as `factsChanged`. `lastSummary` and `stateChanged` stay as they are.

- [x] The two fields, with docs.
- [x] The test hook `InMemorySessionDirectory.setRecap(of:_:at:)`: it sets the two fields and sends `factsChanged`. An archive keeps the recap.
- [x] Tests: no recap by default; the hook sets it and sends one `factsChanged`; the same recap sends no event; archive and unarchive keep it; unknown session; old JSON decodes. #recap