---
assignees:
- claude-code
depends_on:
- 01M1MEFF2N9GDQW2V8TY0E0057
position_column: todo
position_ordinal: '8280'
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

- [ ] `swift build` is clean, with no warning.
- [ ] The package declares no new dependency in `Package.swift`.
- [ ] `PlainTextDoctorRenderer(useColor: false).render(report)` holds no
      `ESC` (`0x1B`) byte, for a report that holds all three statuses.
- [ ] `PlainTextDoctorRenderer(useColor: true).render(report)` holds one
      `ESC` byte or more, for the same report.
- [ ] Each `.warning` row and each `.error` row is followed by a line that
      holds its fix text. An `.ok` row is followed by no such line.
- [ ] `report.jsonData()` decodes back to `[HealthCheck]` equal to
      `report.checks`.

## Tests

New file `Tests/FoundationModelsExtrasTests/DoctorRendererTests.swift`, a
swift-testing `@Suite` with a plain `import FoundationModelsExtras`.

- [ ] Test: the plain output of a three-status report holds no ANSI escape,
      and the `useColor: true` output of the same report holds one
      (doctor-plan.md §8, row 6, and the other half of the §6 rule).
- [ ] Test: the output holds the fix text of each `.warning` and each
      `.error`, and holds no extra line for an `.ok` check. Test also a
      `.error` whose `fix` is `nil`, made with the memberwise init: the row
      is followed by the line that says that no fix was given.
- [ ] Test: the rows keep the order of `report.checks`.
- [ ] Test: `jsonData()` decodes back to a value equal to `report.checks`,
      and `jsonData()` of a one-check report equals an exact expected
      `String`. The exact comparison is what `.sortedKeys` is for
      (doctor-plan.md §8, row 7).
- [ ] Test: `write(_:to:)` against `Pipe().fileHandleForWriting` gives text
      with no ANSI escape, because a pipe is not a terminal. **Close the
      write handle before the read**: `try handle.close()`, then
      `readDataToEndOfFile()` on the read handle. A read to end with the
      write handle still open never returns.
- [ ] Run `swift test --filter Doctor`. Expect all tests to pass, and expect
      the run to end (no hang).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.