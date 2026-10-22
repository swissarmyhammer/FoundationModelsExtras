---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5ja2drn7b3dgrsgds4gfd7d
  text: 'Research: ISO8601JSON has 2 callers (JSONLFile.line/records, MarketplaceState.save/decode). The module already has `DateTime` (GraphQL/Scalars.swift): RFC 3339 UTC with milliseconds, writes ms with integer math (the comment there says ISO8601FormatStyle can write `.001` as `.000` for a Double date), reads with `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` (Sendable value type). Plan: ISO8601JSON date strategies go through `DateTime`''s Codable form instead of copying that logic. MarketplaceCacheTests `aStateFileWithEveryFieldDecodesEachField` holds whole-second fixture strings and must move to `.000Z`.'
  timestamp: 2026-10-22T17:20:49.429236+00:00
- actor: claude-code
  id: 01m5jacnks3v1rx9z6dyw6fm0h
  text: |-
    Implementation landed (not committed).
    - ISO8601JSON encoder: `.custom` strategy that encodes `DateTime(date)`, so the text is RFC 3339 UTC with exactly three-digit milliseconds, written with integer math (no Double-to-`.000` drift). Decoder: `.custom(decodeDate)`, which parses with `DateTime(rfc3339:)` and then requires `time.rfc3339 == text`; anything else throws `DecodingError.dataCorrupted`. No shared mutable formatter: `DateTime` holds `Date.ISO8601FormatStyle` values, which are Sendable.
    - Discovery / dead end: the first attempt decoded with `DateTime(rfc3339:)` alone, and the whole-second test still passed. On this macOS, `Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse` ALSO accepts `1970-01-01T00:00:00Z`. Also, the old `.iso8601` decoder already parsed `.123Z`, so `decoderReadsISO8601Dates` was green before the change. That is why the strict canonical-text check is there.
    - Tests: ISO8601JSONTests now has a sub-second stamp (`.123Z`), plus `aDateRoundTripsAtMillisecondPrecision` and `decoderRejectsADateWithWholeSecondsOnly`. JSONLFileTests has `twoDatesInOneSecondReadBackInTheirOrder`. MarketplaceCacheTests fixture `aStateFileWithEveryFieldDecodesEachField` moved to `.000Z` strings (it decoded whole-second strings, which are no longer read).
    - `swift format lint -s` exits 0 on ISO8601JSON.swift, JSONLFile.swift, ISO8601JSONTests.swift and JSONLFileTests.swift. MarketplaceCacheTests.swift has 13 lint findings that are identical at HEAD, all on lines this card did not touch. Filed as a new task, `MarketplaceCacheTests: fix the swift format lint findings already at HEAD`.
    - Router follow-up from the card: once this lands, send the sha to the Router session (foundationmodelsrouter-08).
  timestamp: 2026-10-22T17:26:25.145003+00:00
- actor: claude-code
  id: 01m5jacqn2neazpgqd8ts6atyt
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/ISO8601JSON.swift, Sources/FoundationModelsExtras/JSONLFile.swift, Tests/FoundationModelsExtrasTests/ISO8601JSONTests.swift, Tests/FoundationModelsExtrasTests/JSONLFileTests.swift, Tests/MarketplaceTests/MarketplaceCacheTests.swift; `swift test` 1557 tests / 160 suites passed, 0 failures, no compiler warnings
    - next: /review
  timestamp: 2026-10-22T17:26:27.234414+00:00
- actor: claude-code
  id: 01m5jaen29nz8s2dn9x5hwp3ht
  text: |-
    ### test — green
    - evidence: `swift test` — 1557 tests in 160 suites passed, 0 failed, 0 skipped, 0 issues; `swift format lint -s` on ISO8601JSON.swift, JSONLFile.swift, ISO8601JSONTests.swift, JSONLFileTests.swift — exit 0, no findings. The only build warning is from the mlx-swift_Cmlx.bundle build-system step (dependency, not our code). MarketplaceCacheTests.swift lint left alone per its own card.
    - next: review/commit
  timestamp: 2026-10-22T17:27:30.121171+00:00
- actor: claude-code
  id: 01m5jaf5qcnank4y3zr94xgrkz
  text: |-
    ### commit — changed
    - evidence: single local commit of green working tree (ISO8601JSON, JSONLFile, tests, all pending .kanban changes incl. MarketplaceCacheTests lint card); sha recorded in the commit itself and reported to the caller
    - next: review
  timestamp: 2026-10-22T17:27:47.180917+00:00
- actor: claude-code
  id: 01m5jaksgjx2ynfxsx2tnj9sqa
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (4024c7d) — 0 findings, 0 confirmed, 0 refuted; 7 attempted, 0 failed; 5 files reviewed, 4 .kanban files excluded by .reviewignore
    - next: send sha 4024c7d to the Router session (foundationmodelsrouter-08)
  timestamp: 2026-10-22T17:30:18.514967+00:00
- actor: claude-code
  id: 01m5jambmymvem88p237v728z2
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files (ISO8601JSON.swift, JSONLFile.swift, ISO8601JSONTests, JSONLFileTests, MarketplaceCacheTests)
    - test: green — swift test, 1557 passed, 0 failed, 0 skipped
    - commit: 4024c7d
    - review: clean — none
  timestamp: 2026-10-22T17:30:37.086132+00:00
position_column: done
position_ordinal: ffc080
title: ISO8601JSON writes and reads ISO 8601 dates with fractional seconds
---
Requested by the Router session (foundationmodelsrouter-08); send it the sha when landed so it can drop its whole-second `sentAt` stamping.

## Problem
`ISO8601JSON.makeEncoder` / `makeDecoder` (Sources/FoundationModelsExtras/ISO8601JSON.swift) use `.iso8601`, which writes whole seconds. Router's transcript `ts` and message `sentAt` round down on disk via JSONLFile, so two events in the same second lose their order and a restored value differs from what was delivered.

## User decision (2026-10-22): shared, fractional only
- The shared `ISO8601JSON` encoder writes ISO 8601 with fractional seconds (e.g. `2026-10-22T10:58:03.123Z`); the decoder reads that format. Every caller (JSONLFile, MarketplaceState) gets it.
- No backward compatibility (ARCHITECTURE.md): whole-second dates are no longer read. Do not add a fallback.
- Keep the formatter safe under concurrency (Swift 6): no shared mutable `ISO8601DateFormatter` across threads unless it is safe; prefer `Date.ISO8601FormatStyle` with `includingFractionalSeconds`.

## Subtasks
- [x] Failing tests first: a Date with sub-second precision round-trips through ISO8601JSON at millisecond precision; the encoded string carries fractional seconds; two dates in the same second keep their order after a JSONLFile append/read; a whole-second date string fails to decode
- [x] Change ISO8601JSON encoder and decoder date strategies
- [x] Update doc comments (ISO8601JSON, JSONLFile line format) to state the format
- [x] `swift test` passes, zero warnings

#cross-repo #recording