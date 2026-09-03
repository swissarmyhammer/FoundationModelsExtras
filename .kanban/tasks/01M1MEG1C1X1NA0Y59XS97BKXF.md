---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1mhyg331rvnhdyeayrkjqpe
  text: |-
    Picked up. Research done.

    Read `Sources/FoundationModelsExtras/Doctor/` whole: `HealthCheck.swift` (HealthStatus is `String`-raw-valued and Codable, so `status.rawValue` gives the wire word for the table; the memberwise `init(name:status:message:fix:category:)` is public, which is what lets a test build a `.error` with `fix: nil`), `Doctorable.swift`, `DoctorReport.swift` (public memberwise init over `checks`), `DoctorRunner.swift`.

    Read `doctor-plan.md` §6 and §8. Read `Package.swift`: no terminal dependency stands there and none is added.

    Facts that shape the work:
    - `HealthCheck` uses a SYNTHESIZED encoder, so a `nil` fix is an ABSENT key, never `null`. That makes the exact-string JSON test stable.
    - The package builds with 4-space indent under `Doctor/`. `AgentsMd.swift` states the `#if canImport(Darwin) / import Darwin` shape this package uses to reach a POSIX symbol; `isatty` needs it.
    - `Sources/Operations/AnyOperation.swift` already sets `encoder.outputFormatting = [.sortedKeys]`, so the stable-bytes idiom is the prevailing one here.
    - `DoctorRunnerTests.swift` is the pattern to follow: plain `import FoundationModelsExtras` (no `@testable`), a `@Suite` with named `private static let` constants for every word and number the tests carry.

    Loaded the review rules for `.swift` (60 rules). The ones that shape this file: every `public` declaration takes a doc comment; every numeric literal outside `0/1/-1/100` takes a name; a top-level `func` is forbidden (a namespace enum holds the ANSI sequences); build a collection with `map`, never a `var` accumulator; a `switch` over `HealthStatus` carries no `default:`.
  timestamp: 2026-09-03T21:14:10.915123+00:00
- actor: claude-code
  id: 01m1mja21mm4psh5wfm6g0yy51
  text: |-
    Implementation landed, by `/tdd`.

    RED first: the test file went in before the renderer, and `swift build --build-tests` failed with `cannot find 'PlainTextDoctorRenderer' in scope` and `value of type 'DoctorReport' has no member 'jsonData'` — the feature missing, not a typo.

    Two tests were written after the code, so each was watched to fail on purpose before it was trusted:
    - `theMessageColumnStartsAtTheSameOffsetWhateverTheNameLength` — padding turned off, the test failed on the offsets, padding restored.
    - `theColoredWarningAndErrorRowsEachHoldAnAnsiEscape` — coloring turned off, the test failed on BOTH the warning row and the error row, coloring restored.

    Decisions worth carrying forward:
    - `write(_:to:)` deliberately does NOT read `useColor`. It reads `isatty(handle.fileDescriptor)` and builds a renderer of its own, so a pipe gets plain text however the receiver was built. The pipe test proves it: it calls `write` on a renderer built with `useColor: true` and asserts no escape came out.
    - The colors are named for what they SAY (`passing`, `attention`, `broken`) rather than for the color they paint, matching the private constant names of `DoctorReport`.
    - The status word is padded BEFORE it is colored, so the escape sequences never enter the width the padding counts and the columns line up in the colored rendering too.
    - The column widths are measured off the report, not fixed, so a report of short names carries no padding a report of long ones would need.

    Two things that did not work:
    - `#expect(text.unicodeScalars.allSatisfy(\.isASCII))` does not compile. The `#expect` macro decomposes a function call apart and reads `allSatisfy`, which is `rethrows`, as a call that can throw. The reading is now made into a `let` above the macro, with a comment stating why.
    - A message that repeats a name of another row breaks a `contains` search. `passingMessage` was "the configuration loaded" beside `passingName` "configuration"; it is now "the settings loaded", and the file states the rule that no message repeats a name.

    `Package.swift` and `Package.resolved` are untouched — `git diff --stat` on both is empty, so the no-terminal-dependency rule of §6 holds.
  timestamp: 2026-09-03T21:20:29.748375+00:00
- actor: claude-code
  id: 01m1mja75evcasntaf5cj492d5
  text: |-
    ### implement — changed
    - evidence: 2 files — /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Sources/FoundationModelsExtras/Doctor/DoctorRenderer.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Tests/FoundationModelsExtrasTests/DoctorRendererTests.swift. `swift build`: Build complete, 0 warnings. `swift test --filter Doctor`: 31 tests in 3 suites passed, the run ended. Full `swift test`: 250 tests in 23 suites passed, 0 warnings, 0 failures. `git diff --stat -- Package.swift Package.resolved`: empty.
    - next: `/review`
  timestamp: 2026-09-03T21:20:34.990530+00:00
depends_on:
- 01M1MEFF2N9GDQW2V8TY0E0057
position_column: doing
position_ordinal: '80'
title: Add the plain-text doctor renderer and the JSON output
---
## What

Add the renderer of `doctor-plan.md` §6 (milestone D3). It turns a
`DoctorReport` into text a person reads, or into JSON a script reads.

**The rule that governs this task:** this package must stay free of a
terminal dependency, because it is a library that also runs in a Mac app.
Add no package dependency. A CLI that wants a decorated table renders the
`DoctorReport` itself.

File to create:

- `Sources/FoundationModelsExtras/Doctor/DoctorRenderer.swift`
  - `public struct PlainTextDoctorRenderer: Sendable`
    - `public init(useColor: Bool = false)`.
    - `public func render(_ report: DoctorReport) -> String` — one row for
      each check, with the columns status, name, and message, in aligned
      columns. Under a `.warning` row and under an `.error` row, it writes
      the fix line, with an indent.
    - `public func write(_ report: DoctorReport, to handle: FileHandle)
      throws` — it selects the color from
      `isatty(handle.fileDescriptor) == 1`, then it writes the text with
      `handle.write(contentsOf:)`. The function **throws**, because
      `write(contentsOf:)` throws; the older non-throwing `write(_:)` raises
      an Objective-C exception that Swift cannot catch. This keeps the
      terminal test in the library and out of each CLI.
  - An extension on `DoctorReport`:
    - `public func jsonData(prettyPrinted: Bool = false) throws -> Data` —
      it encodes `checks` as one JSON array, with `.sortedKeys` on the
      encoder, so the bytes are stable and a test can compare them.

Rules the renderer obeys:

- With `useColor == false`, the output holds no ANSI escape and no
  box-drawing character. Use only ASCII, so the output is stable and
  testable.
- With `useColor == true`, a `.warning` row and an `.error` row hold an ANSI
  color escape. This is the other half of the §6 rule, and a test pins it.
- A `.warning` or an `.error` **can** hold a `nil` fix, because a decoder can
  make one (see the `HealthCheck` task). In that case the renderer writes
  the fix line, and the line says that the component gave no fix. The
  problem must stay visible; a missing fix must not make a silent row.
- The report writes to stderr and the JSON writes to stdout. That selection
  belongs to the CLI, not to this type: `write(_:to:)` takes the destination
  as a parameter.

## Acceptance Criteria

- [x] `swift build` is clean, with no warning.
- [x] The package declares no new dependency in `Package.swift`.
- [x] `PlainTextDoctorRenderer(useColor: false).render(report)` holds no
      `ESC` (`0x1B`) byte, for a report that holds all three statuses.
- [x] `PlainTextDoctorRenderer(useColor: true).render(report)` holds one
      `ESC` byte or more, for the same report.
- [x] Each `.warning` row and each `.error` row is followed by a line that
      holds its fix text. An `.ok` row is followed by no such line.
- [x] `report.jsonData()` decodes back to `[HealthCheck]` equal to
      `report.checks`.

## Tests

New file `Tests/FoundationModelsExtrasTests/DoctorRendererTests.swift`, a
swift-testing `@Suite` with a plain `import FoundationModelsExtras`.

- [x] Test: the plain output of a three-status report holds no ANSI escape,
      and the `useColor: true` output of the same report holds one
      (doctor-plan.md §8, row 6, and the other half of the §6 rule).
- [x] Test: the output holds the fix text of each `.warning` and each
      `.error`, and holds no extra line for an `.ok` check. Test also a
      `.error` whose `fix` is `nil`, made with the memberwise init: the row
      is followed by the line that says that no fix was given.
- [x] Test: the rows keep the order of `report.checks`.
- [x] Test: `jsonData()` decodes back to a value equal to `report.checks`,
      and `jsonData()` of a one-check report equals an exact expected
      `String`. The exact comparison is what `.sortedKeys` is for
      (doctor-plan.md §8, row 7).
- [x] Test: `write(_:to:)` against `Pipe().fileHandleForWriting` gives text
      with no ANSI escape, because a pipe is not a terminal. **Close the
      write handle before the read**: `try handle.close()`, then
      `readDataToEndOfFile()` on the read handle. A read to end with the
      write handle still open never returns.
- [x] Run `swift test --filter Doctor`. Expect all tests to pass, and expect
      the run to end (no hang).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.