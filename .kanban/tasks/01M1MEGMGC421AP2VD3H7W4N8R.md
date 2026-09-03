---
assignees:
- claude-code
depends_on:
- 01M1MEG1C1X1NA0Y59XS97BKXF
- 01M1MEVHZNW7ZF0EQVFVXJ3X17
position_column: todo
position_ordinal: '8380'
title: extras-demo doctor subcommand + integration test
---
## What

Give the doctor surface the same living contract test that each other
capability of this package has (plan.md §7): an `extras-demo` subcommand,
driven as a subprocess by an integration test. This is the only honest way
to prove two claims of `doctor-plan.md` that a unit test cannot prove: the
exit code that a script reads, and the rule that a pipe gets no ANSI.

Files to create or to change:

- Create `Examples/ExtrasDemo/Sources/extras-demo/DoctorCommand.swift`
  - `struct DoctorCommand: AsyncParsableCommand`, command name `doctor`.
  - Flags: `--json`, and `--scenario <ok|warning|error|mixed>` that selects
    a set of demo `Doctorable` components made in the file itself.
  - **The components are pinned, because the tests name them:**
    - Each scenario holds a component named `disabled-component`, whose
      `isApplicable` is `false`. That name is in no other text of the
      output, so a test can assert its absence.
    - The `error` scenario holds a component named `error-component`, whose
      check is a `.error` with the fix text `run extras-demo doctor --help`.
      The tests assert on both strings.
    - The `warning` scenario holds a component named `warning-component`,
      with a `.warning` and its own fix text.
    - The `mixed` scenario holds all of these together with an `.ok`
      component.
  - It builds a `DoctorRunner`, it awaits `run()`, and then:
    - without `--json`: it writes `PlainTextDoctorRenderer` output to
      **stderr**, with `try write(report, to: FileHandle.standardError)`.
    - with `--json`: it writes `report.jsonData()` to **stdout**.
    - It ends with `throw ExitCode(report.exitCode)`. ArgumentParser gives
      an `ExitCode` its raw value directly, `0` included.
- Change `Examples/ExtrasDemo/Sources/extras-demo/main.swift`: add
  `DoctorCommand.self` to `subcommands`, and name it in the doc comment.
- Change `Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift`:
  add the doctor tests, with the two-stream `run(arguments:)` harness that
  the task it depends on gives.

## Acceptance Criteria

- [ ] `swift run extras-demo doctor --scenario ok` writes its table to
      stderr, leaves stdout empty, and exits `0`.
- [ ] `--scenario error` exits `1`, and `--scenario warning` exits `5`.
- [ ] `--scenario mixed --json` writes a JSON array to stdout, and writes no
      table to stdout.
- [ ] The component that is not applicable puts no row in the output.

## Tests

- [ ] Test: `--scenario ok` exits `0`; `--scenario warning` exits `5`;
      `--scenario error` exits `1` (doctor-plan.md §8, row 3, end to end).
- [ ] Test: **the `error` run also holds the text `error-component` and its
      fix text in `stderr`.** Without this, the test passes on any failure
      of the demo command, because ArgumentParser also exits `1` for any
      error it does not know.
- [ ] Test: `stderr` holds the table and `stdout` is empty, for a run with
      no `--json`.
- [ ] Test: the output of a run holds no ANSI escape (`0x1B`), because the
      harness gives the process a `Pipe` and not a terminal
      (doctor-plan.md §8, row 6, end to end).
- [ ] Test: `--json` output parses with `JSONSerialization` as an array from
      `stdout`, each element holds the keys `name`, `status`, `message`, and
      `category`, and `stdout` holds no table text.
- [ ] Test: `disabled-component` is absent from `stdout` and from `stderr`,
      in the `mixed` scenario, both with `--json` and without it.
- [ ] Run `swift test --filter ExtrasDemoIntegrationTests`. Expect all tests
      to pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.