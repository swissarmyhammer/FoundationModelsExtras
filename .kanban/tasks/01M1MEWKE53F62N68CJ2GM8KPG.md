---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1mmm2cn9ackdpe0m3kh9snn
  text: |-
    Research before writing, and what the verification found.

    Read the real public surface first, not the plan: `Sources/FoundationModelsExtras/Doctor/{HealthCheck,Doctorable,DoctorReport,DoctorRunner,DoctorRenderer}.swift` and `Examples/ExtrasDemo/Sources/extras-demo/DoctorCommand.swift`.

    Facts the section depends on, each read off the code:
    - `HealthCheck.error(name:message:fix:category:)` takes a non-optional `fix`. `.ok(name:message:category:)` takes none.
    - `Doctorable` gives `doctorName`, `doctorCategory`, `isApplicable` (defaults to `true`), and `runHealthChecks() async -> [HealthCheck]`. It returns and does not throw.
    - `DoctorRunner(components:)` takes `[any Doctorable]`; `run()` is `async` and is not `throws`, so the call site is `await runner.run()` with no `try`.
    - `DoctorReport.exitCode` is `Int32`, and its three codes are private static constants: `0`, `1`, `5`.
    - The `--json` output is `DoctorReport.jsonData(prettyPrinted:)`, an extension in `DoctorRenderer.swift`, and `DoctorCommand` calls it as `report.jsonData()`.
    - `extras-demo` is an executable target of the ROOT package (`path: "Examples/ExtrasDemo/Sources/extras-demo"`), not a nested package. `swift run extras-demo ...` therefore runs from the repository root with no `--package-path`.

    Verification, run rather than assumed:
    - `swift run extras-demo doctor --scenario mixed` from the repository root: exit code `1`. The report holds one `ok`, one `warning` and one `error` row on stderr; `disabled-component` is silent. This is what the section states.
    - The README Swift block was compiled and executed, not read. A scratch SwiftPM package in the scratchpad (`ReadmeDoctorCheck`) depends on the local package by path and holds the block verbatim in `main.swift`, with `precondition` lines under it. It builds and prints `readme doctor block ok`, so `report.worstStatus == .error` and `report.exitCode == 1` are proved, not claimed.

    `dump validators` for `.md` returns zero rules, so no validator rule applies to this file.
  timestamp: 2026-09-03T22:00:54.933113+00:00
- actor: claude-code
  id: 01m1mmm8cdahpnrdjhcbdrzwa6
  text: |-
    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/README.md. New `## Health checks: Doctorable` section before `## Install`, naming `Doctorable`, `HealthCheck`, `DoctorRunner`, `DoctorReport` and `PlainTextDoctorRenderer`, with the 0/1/5 exit-code table, the stderr/stdout split of doctor-plan.md §6, and `swift run extras-demo doctor --scenario mixed`. Verified: that command exits `1`; the README Swift block builds and runs (`readme doctor block ok`); `swift build` exit 0; `swift test` 258 tests in 23 suites passed, 0 failures, 0 compiler warnings.
    - next: /review
  timestamp: 2026-09-03T22:01:01.069603+00:00
depends_on:
- 01M1MEGMGC421AP2VD3H7W4N8R
position_column: doing
position_ordinal: '80'
title: Document Doctorable in README
---
## What

Give the doctor surface its README section, as
`Document IgnoreProcessor in README` did for `IgnoreProcessor`.

Change `README.md`: add a section `## Health checks: Doctorable` before
`## Install`. Keep the style and the length of the
`## Ignoring files: IgnoreProcessor` section that is there now.

The section holds:

- One short paragraph: a CLI has one command that answers one question —
  will this configuration work? — and the answer is a list of named checks,
  each with a status, a message, and, when something is wrong, the command
  that fixes it.
- A short Swift block: a `Doctorable` conformance with one check made with
  `HealthCheck.error(name:message:fix:category:)`, then a `DoctorRunner`
  built over it, then `await runner.run()`, then the exit code.
- The exit-code table of `doctor-plan.md` §5: `0` all checks are `.ok`,
  `1` one `.error` or more, `5` a `.warning` and no `.error`.
- Two sentences on the split of §6: the table goes to stderr, `--json` goes
  to stdout, and the package holds no terminal dependency, so a CLI that
  wants a decorated table renders the `DoctorReport` itself.
- The command `swift run extras-demo doctor --scenario mixed`, as the
  runnable example.

## Acceptance Criteria

- [ ] `README.md` holds the new section, before `## Install`.
- [ ] The section names `Doctorable`, `HealthCheck`, `DoctorRunner`, and
      `DoctorReport`, and it gives the three exit codes.
- [ ] The Swift block compiles against the public surface: the names, the
      argument labels, and the `await` match the code that was written.
- [ ] The `swift run` command in the section runs and gives the exit code
      the section states.

## Tests

- [ ] Run the command that the section gives:
      `swift run extras-demo doctor --scenario mixed`. Expect exit code `1`,
      because the mixed scenario holds an `.error`.
- [ ] Run `swift build` and `swift test`. Expect no failure, so the section
      cannot name a surface that is not there.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.