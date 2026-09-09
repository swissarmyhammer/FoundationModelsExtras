---
comments:
- actor: claude-code
  id: 01m21jmkbmc53jb3eqmywafgh2
  text: |-
    Picked up. Research done.

    The Doctor module is on `main` from three earlier cards (commits b044d69, aae3b89, 939b317, plus the demo and the README). D1 and D2 match this card. These are the gaps:

    1. `DoctorReport` is not `Codable`. The card says `HealthCheck` and `DoctorReport` go through JSON and come back equal. Only `jsonData()` exists, and it encodes `checks`.
    2. `PlainTextDoctorRenderer` has a `useColor` option, a `TerminalStyle` enum with escape sequences, an `isatty` test in `write(_:to:)`, and `import Darwin`. The card says: no ANSI escape, ever, and no terminal import in the module.
    3. The card names `DoctorReportTests` and `PlainRendererTests`. The exit-code tests are in `DoctorRunnerTests`, and the renderer tests are in `DoctorRendererTests`.
    4. No test measures N components that each wait 100 ms. The existing concurrency test uses a hand-off signal.

    Callers of the renderer: `Examples/ExtrasDemo/Sources/extras-demo/DoctorCommand.swift` (`write(_:to:)` and `jsonData()`), the README, and `ExtrasDemoIntegrationTests`. `FoundationModelsACPAgent` has only a stub `Doctor` subcommand and uses no part of the API yet.

    Plan: TDD in three cycles. (a) `DoctorReport: Codable`, encoded as the bare array of its checks, so the bytes equal `jsonData()`. (b) A timing test in `DoctorRunnerTests`; RED is shown with the runner made serial for one run. (c) Remove every escape sequence and the terminal test from the renderer; a source-scan test holds the module to no escape spelling and to `import Foundation` only. Shared stand-in findings move to `DoctorTestSupport.swift` so two suites do not copy them.
  timestamp: 2026-09-08T22:36:22.772304+00:00
- actor: claude-code
  id: 01m21k5yqad0dq652j8r53sgxb
  text: |-
    Implementation landed, in three TDD cycles. Each RED was seen before its GREEN.

    Cycle (a), `DoctorReport` through JSON. RED: the test target did not compile, because `DoctorReport` did not conform to `Encodable` or `Decodable`. GREEN: `DoctorReport: Codable` with a single-value container over `checks`, so the JSON form is the one array of findings and `jsonData()` now encodes `self`. Seven tests in `DoctorReportTests` pass.

    Cycle (b), the timing test. RED: with `run()` made serial for one run, ten components that each sleep 100 ms took 1.022 s, over the 0.5 s limit, and the hand-off test also failed through its watchdog. GREEN: the task-group runner restored (no diff against HEAD); the ten sleepers finish in 0.105 s.

    Cycle (c), no escape sequence, ever. RED: two source-scan tests failed, because `DoctorRenderer.swift` spelled the escape character and imported `Darwin`. GREEN: the renderer has no `useColor`, no `TerminalStyle`, no `isatty` and no `Darwin` import; `write(_:to:)` writes the bytes of `render(_:)` unchanged. The colored-output test is deleted, because the card forbids that behavior.

    Test names in the three doctor test files are raw identifiers (for example `a report survives a json round trip`), because swiftformat's `swiftTestingTestCaseNames` rule in the `idioms-swift` roster requires that form. `DoctorableTests` keeps its earlier camelCase names, because that file did not change. Stand-in findings and the three exit codes moved to `DoctorTestSupport.swift`, so `DoctorReportTests` and `DoctorRunnerTests` hold no copy.

    What did not work: the automatic rename by swiftformat writes names such as `an error outranks A warning` and `AJSON round trip`, so the raw-identifier names were written by hand.

    The last acceptance criterion, the change on `main`, is for the commit step: the branch is `main`, and nothing is committed yet.
  timestamp: 2026-09-08T22:45:51.466630+00:00
- actor: claude-code
  id: 01m21k6c9dxwgghfpsexv0fg2r
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsExtras/Doctor/DoctorReport.swift, Sources/FoundationModelsExtras/Doctor/DoctorRenderer.swift, Tests/FoundationModelsExtrasTests/DoctorTestSupport.swift (new), Tests/FoundationModelsExtrasTests/DoctorReportTests.swift (new), Tests/FoundationModelsExtrasTests/DoctorRunnerTests.swift, Tests/FoundationModelsExtrasTests/PlainRendererTests.swift (renamed from DoctorRendererTests.swift), Examples/ExtrasDemo/Sources/extras-demo/DoctorCommand.swift, README.md. `swift test`: 264 tests in 24 suites passed in the package bundle, plus 94, 34, 44 and 22 tests in the other bundles — 458 tests, 0 failures, 0 skipped, 0 compiler warnings on a rebuild of the touched files. `swiftformat --lint` with the idioms-swift roster over the 6 changed Swift files: 0 of 6 need formatting.
    - next: /review. The commit step satisfies the one open acceptance criterion, the change on `main`. Nothing is committed and nothing is pushed.
  timestamp: 2026-09-08T22:46:05.357936+00:00
- actor: claude-code
  id: 01m21kd0kmtpd4w4y6s8eabc74
  text: |-
    ### test — green
    - command: `swift test` (full clean rebuild, `swift package clean` then `swift test`)
    - result: 264 tests, 24 suites, all passed. Build had 0 warnings and 0 errors.
    - checks done: no skipped or disabled tests found in Tests/. No lint config file at repo root (.swiftlint.yml / .swiftformat / .swift-format), and Package.swift does not use the Airbnb plugin, so no extra lint step applies.
    - no code changes were needed. No commit was made.
    - next: ready for review.
  timestamp: 2026-09-08T22:49:42.772832+00:00
- actor: claude-code
  id: 01m21ke8tqvtfvbtgxhy868kfy
  text: |-
    ### commit — changed
    - evidence: f80146f, 10 files changed
    - next: send the task for review.
  timestamp: 2026-09-08T22:50:23.959134+00:00
- actor: claude-code
  id: 01m21kxrr0b8r4vtvhae4zvwjb
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit f80146f), backend local. Counts: 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 8 files reviewed. Not reviewed: 2 files in `.kanban/` (ignore rule), `README.md` (no validator).
    - note: five `code-hygiene` rules declined the old path `Tests/FoundationModelsExtrasTests/DoctorRendererTests.swift`. The commit renamed that file to `PlainRendererTests.swift`, so the old path does not exist. This is not a finding.
    - next: no review finding is open. The task moved from `doing` to `review` to `done`.
  timestamp: 2026-09-08T22:58:51.776497+00:00
- actor: claude-code
  id: 01m21kyg9y97exkqxzz9ykjax2
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files
    - test: green — swift test, 264 tests, 24 suites, 0 failed, 0 warnings
    - commit: f80146f
    - review: clean — 0 findings, 8 files reviewed
    - column: done
  timestamp: 2026-09-08T22:59:15.902378+00:00
position_column: done
position_ordinal: 9f80
title: 'Doctorable module: D1 to D3'
---
## What

Add the `Doctorable` module: milestones **D1, D2 and D3** of this
repository's `doctor-plan.md`. All three are in one card, because D3's
plain renderer is what a piped `doctor` needs, and no other card owns
it.

Asked for by `FoundationModelsACPAgent`, card `^p483a8w`, which blocks
its `doctor` subcommand and its `acp-client doctor`.

New module `Sources/FoundationModelsExtras/Doctor/`:

**D1 — the protocol and the values.**
- `HealthStatus`: `ok`, `warning`, `error`. `Sendable`, `Codable`.
- `HealthCheck`: `name`, `status`, `message`, `fix: String?`,
  `category`. `Sendable`, `Equatable`, `Codable`. Static makers where
  `warning` and `error` require a `fix`.
- `Doctorable`: `doctorName`, `doctorCategory`, `isApplicable` (default
  `true`), `func runHealthChecks() async -> [HealthCheck]` (default: one
  `.ok` built from the name and the category).

**D2 — the runner.**
- `DoctorReport`: `checks`, `worstStatus`, `exitCode` — 0 for all `.ok`,
  1 for any `.error`, 5 for warnings with no error.
- `DoctorRunner`: `init(components:)` and `run() async -> DoctorReport`.
  Concurrent in a task group, it skips components that are not
  applicable, and it keeps the registration order in the result.
- `runHealthChecks()` never throws. A check that cannot run reports
  `.error` with the reason, so one broken check cannot stop the others.

**D3 — the plain renderer and the JSON.**
- A plain-text renderer for `DoctorReport`: status, name, message, with
  the fix line under each `.warning` and `.error` row. **No ANSI escape,
  ever** — this is the renderer a piped `doctor` uses, and a decorated
  table is the CLI's own concern.
- `HealthCheck` and `DoctorReport` encode to JSON for the `--json` form.

**This module declares no terminal dependency.** Extras is a library
that also runs inside a Mac app.

- [x] D1: `HealthStatus`, `HealthCheck`, `Doctorable`
- [x] D2: `DoctorReport` and `DoctorRunner`
- [x] D3: the plain renderer, and the JSON encoding

## Acceptance Criteria

- [x] A type that declares only `doctorName` and `doctorCategory`
      compiles and gives one `.ok` check.
- [x] `exitCode` gives 0, 1 and 5 for the three cases.
- [x] N components that each wait 100 ms finish in well under
      N x 100 ms.
- [x] The report order matches the registration order, whatever the
      finish order.
- [x] The plain renderer output holds no `ESC[` sequence, ever.
- [x] No file in the module imports a terminal or a color library.
- [ ] The change is on `main`, because consumers track the `main` branch
      and not a version.

## Tests

- [x] `DoctorableTests`: the default implementation gives exactly one
      `.ok` check, named and categorized from the protocol properties.
- [x] `isApplicable == false` contributes no checks, and the component
      stays in the runner's list.
- [x] `DoctorReportTests`: the exit code of each of the three cases.
- [x] `DoctorRunnerTests`: the concurrency timing assertion, and a
      stable order.
- [x] `PlainRendererTests`: the output holds no `ESC[`, and each
      `.warning` and `.error` row is followed by its fix line.
- [x] `HealthCheck` and `DoctorReport` go through JSON and come back
      equal.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.