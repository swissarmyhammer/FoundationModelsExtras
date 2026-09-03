---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1mkw6ehm0g8e4fmjvqea48r
  text: |-
    Research done. Findings that shape the work:

    - Doctor public surface read: `Doctorable` (doctorName, doctorCategory, isApplicable, runHealthChecks), `HealthCheck.ok/.warning/.error`, `DoctorRunner(components:)` + `run()`, `DoctorReport.exitCode` (0/1/5), `PlainTextDoctorRenderer.write(_:to:)` and `DoctorReport.jsonData(prettyPrinted:)`. All public, no `@testable` needed.
    - `PlainTextDoctorRenderer.write(_:to:)` reads `isatty` on the destination itself and ignores `useColor`, so a `Pipe` destination gets plain text with no work by the command. That is what makes the no-ANSI test end to end.
    - ArgumentParser exit-code path VERIFIED in the checkout, not assumed. `MessageInfo.init` holds `case let exitCode as ExitCode: self = .other(message: "", exitCode: exitCode)`, and `ParsableArguments.exit(withError:)` ends in `Platform.exit(messageInfo.exitCode.rawValue)`. The empty message prints nothing, and the raw value passes through unchanged, `0` included. So `throw ExitCode(report.exitCode)` is correct for all three codes.
    - The same read confirms WHY the exit-code tests need output assertions: every error ArgumentParser does not recognise becomes `.other(message:, exitCode: .failure)`, which is exit 1 — the same code the doctor uses for `.error`. A bare `exitCode == 1` assertion therefore passes on a crashed command.
    - The repository holds no `.swiftlint.yml`, so `no_direct_standard_out_logs` is live for the new file. The doctor command writes through `FileHandle` only and never calls `print`, so this costs nothing.
    - Test harness `RunResult` already carries `stdout`, `stderr`, `exitCode` and the joined `output`. The new tests use the separate streams.
  timestamp: 2026-09-03T21:47:52.657407+00:00
- actor: claude-code
  id: 01m1mm2pt8hd9jqrfs1d87nbkr
  text: |-
    TDD record, for the next agent.

    RED: the seven doctor tests went in first. The first run failed all of them with `Error: Unknown option '--scenario'` at exit 64 — no `doctor` subcommand, which is the right reason.

    Two of the seven passed on that first run, and both were dishonest. `doctorNeverReportsTheComponentThatDoesNotApply` and `doctorWritesNoAnsiEscapeWhenItsDestinationIsAPipe` assert an ABSENCE, and an absent report satisfies an absence. Each gained a positive assertion that the report was in fact produced (`ok-component` on the stream under test, `error-component` for the ANSI one) before the absence is read. All seven then failed, and each failed on the missing command.

    GREEN: `DoctorCommand.swift` plus one name in `main.swift`'s subcommand list. `swift test --filter ExtrasDemoIntegrationTests` 19/19, full `swift test` 258/258, `swift build --build-tests` with zero warnings.

    Two design points worth keeping:

    - `disabled-component` carries an `.error` check, not an `.ok` one. A runner that ever stopped reading `isApplicable` would then both print the name and turn the exit code to 1, so the silence the component exists to prove is a silence the tests can see the loss of. An `.ok` check there would make the same test pass on a broken runner.
    - The `--json` "no table" assertion reads `"    fix: "`, the renderer's own indent and label together. `"fix:"` alone was rejected: the compact JSON writes `"fix":`, and whether that matches turns on a quote character, which is not a contract worth pinning a test to.

    Verified by hand against the built binary: ok -> exit 0, table on stderr, 0 bytes on stdout; warning -> 5; error -> 1; mixed --json -> the three-element array on stdout and 0 bytes on stderr. `disabled-component` appears in none of the five runs.

    README untouched — that is ^2gm8kpg. A note recording the split was added to the card's description.
  timestamp: 2026-09-03T21:51:26.024487+00:00
- actor: claude-code
  id: 01m1mm2v5se8dc6s0ehssbytdd
  text: |-
    ### implement — changed
    - evidence: 3 files — Examples/ExtrasDemo/Sources/extras-demo/DoctorCommand.swift (new), Examples/ExtrasDemo/Sources/extras-demo/main.swift, Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift. `swift build --build-tests` 0 warnings; `swift test --filter ExtrasDemoIntegrationTests` 19/19 passed; `swift test` 258 tests in 23 suites passed.
    - next: ready for /review
  timestamp: 2026-09-03T21:51:30.489110+00:00
- actor: claude-code
  id: 01m1mmeqxqzfrqew7fky9bfy5f
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit e814610) — 0 findings, 0 confirmed, 0 refuted, 7 validator passes attempted, 0 failed. 3 files reviewed; 4 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to `done`. No findings to record.
  timestamp: 2026-09-03T21:58:00.375058+00:00
- actor: claude-code
  id: 01m1mmf73zyh673sdeb1h3jxnm
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files (DoctorCommand.swift, main.swift, ExtrasDemoIntegrationTests.swift); README split out to ^2gm8kpg and left untouched
    - test: green — `swift test`, 452 tests across 5 targets, 0 failed, 0 warnings, 0 skipped
    - commit: e814610 feat(extras-demo): add doctor subcommand for the Doctorable health-check surface
    - review: clean — 0 findings, 7 validator passes
    - next: task is in done; loop moves to ^2gm8kpg, the last of the six
  timestamp: 2026-09-03T21:58:15.935360+00:00
depends_on:
- 01M1MEG1C1X1NA0Y59XS97BKXF
- 01M1MEVHZNW7ZF0EQVFVXJ3X17
position_column: done
position_ordinal: 9c80
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

- [x] `swift run extras-demo doctor --scenario ok` writes its table to
      stderr, leaves stdout empty, and exits `0`.
- [x] `--scenario error` exits `1`, and `--scenario warning` exits `5`.
- [x] `--scenario mixed --json` writes a JSON array to stdout, and writes no
      table to stdout.
- [x] The component that is not applicable puts no row in the output.

## Tests

- [x] Test: `--scenario ok` exits `0`; `--scenario warning` exits `5`;
      `--scenario error` exits `1` (doctor-plan.md §8, row 3, end to end).
- [x] Test: **the `error` run also holds the text `error-component` and its
      fix text in `stderr`.** Without this, the test passes on any failure
      of the demo command, because ArgumentParser also exits `1` for any
      error it does not know.
- [x] Test: `stderr` holds the table and `stdout` is empty, for a run with
      no `--json`.
- [x] Test: the output of a run holds no ANSI escape (`0x1B`), because the
      harness gives the process a `Pipe` and not a terminal
      (doctor-plan.md §8, row 6, end to end).
- [x] Test: `--json` output parses with `JSONSerialization` as an array from
      `stdout`, each element holds the keys `name`, `status`, `message`, and
      `category`, and `stdout` holds no table text.
- [x] Test: `disabled-component` is absent from `stdout` and from `stderr`,
      in the `mixed` scenario, both with `--json` and without it.
- [x] Run `swift test --filter ExtrasDemoIntegrationTests`. Expect all tests
      to pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Note on scope

The README section this card first named is its own task, ^2gm8kpg. This
card changes no README.