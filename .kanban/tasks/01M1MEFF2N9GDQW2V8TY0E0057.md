---
assignees:
- claude-code
depends_on:
- 01M1MEEW531GZ4EPVACAV737FR
position_column: todo
position_ordinal: '8180'
title: 'Add DoctorRunner and DoctorReport: concurrent run, stable order, exit codes'
---
## What

Add the runner and the report of `doctor-plan.md` §4 and §5 (milestone D2).
The runner collects the checks of each component. The report holds them, and
it computes the exit code that a script reads.

Files to create:

- `Sources/FoundationModelsExtras/Doctor/DoctorReport.swift`
  - `public struct DoctorReport: Sendable, Equatable`.
  - `public let checks: [HealthCheck]`, and `public init(checks:)`.
  - `public var worstStatus: HealthStatus` — `.error` if one check or more is
    `.error`; else `.warning` if one check or more is `.warning`; else `.ok`.
    An empty report is `.ok`.
  - `public var exitCode: Int32` — `0` for `.ok`, `1` for `.error`, `5` for
    `.warning`.
  - In the doc comment of `exitCode`, give the table of the three codes and
    point to `doctor-plan.md` §5 as the source of the decision. **Do not
    write that `2` is the usage-exit code of this package's CLIs.** The CLIs
    here are ArgumentParser CLIs, and ArgumentParser exits `64` for a usage
    error. Write only that the codes come from §5, and that `1` and `5` were
    selected to keep the doctor codes clear of the usage codes.
- `Sources/FoundationModelsExtras/Doctor/DoctorRunner.swift`
  - `public struct DoctorRunner: Sendable`.
  - `public let components: [any Doctorable]` and
    `public init(components: [any Doctorable])`. The components stay in the
    runner, also the ones that do not apply.
  - `public func run() async -> DoctorReport`.

How `run()` works:

- It skips each component whose `isApplicable` is `false`. Such a component
  gives no check, and it is not an error.
- It runs the applicable components **at the same time**, in a
  `withTaskGroup`. Each child gives back its index together with its checks.
- It puts the results in the order the components were registered in, by a
  sort on the index. The report is stable (doctor-plan.md §4).

## Acceptance Criteria

- [ ] `swift build` is clean, with no warning.
- [ ] `DoctorRunner(components: []).run()` gives an empty report whose
      `exitCode` is `0`.
- [ ] A component with `isApplicable == false` puts no check in the report,
      and stays in `runner.components`.
- [ ] The order of the checks in the report is the order of the components in
      the initializer, and it does not change with the speed of a component.
- [ ] The doc comment of `exitCode` makes no claim about the usage-exit code
      of the other CLIs in the family.

## Tests

All of these go in one new file,
`Tests/FoundationModelsExtrasTests/DoctorRunnerTests.swift` — a swift-testing
`@Suite` with a plain `import FoundationModelsExtras`.

- [ ] Test: `exitCode` is `0` when every check is `.ok`; `1` when one check
      is `.error` (also together with a `.warning`); `5` when there is a
      `.warning` and no `.error` (doctor-plan.md §8, row 3).
- [ ] Test: a component with `isApplicable == false` gives no check, and
      `runner.components.count` still counts it (§8, row 2).
- [ ] Test: the report order is the registration order (§8, row 5). Make the
      **first** component slow with a plain `try? await Task.sleep(...)`,
      and the second one fast. This catches the true defect: a runner that
      appends each result as it arrives, in place of a sort on the index. Use
      no signal between the components in this test.
- [ ] Test: one slow component does not hold back the others (§8, row 4).
      Build a small `actor Signal` in the test file, which holds a
      `isSignaled` flag and an optional continuation:
      `wait()` returns immediately if the flag is already set, and
      `signal()` sets the flag and resumes a continuation if one is stored.
      This makes the handoff safe in both directions, because a `signal()`
      that comes before the `wait()` is not lost.
      Component A awaits the signal. Component B sets it. A watchdog child
      task sleeps a bounded time, then sets the signal and sets a
      `watchdogFired` flag. Assert `watchdogFired == false`. A serial runner
      then **fails** and ends; it does not hang.
      **Do not** use a bare `withCheckedContinuation` with only a
      `.timeLimit` trait: swift-testing enforces a time limit by
      cancellation, a pending continuation is not resumed by cancellation,
      and the test would hang. Keep `.timeLimit(.minutes(1))` as a last
      backstop only, and say so in a comment.
- [ ] Test: a component whose checks are all `.error` does not stop the
      checks of the other components (doctor-plan.md §4).
- [ ] Run `swift test --filter Doctor`. Expect all tests to pass, and expect
      the run to end (no hang).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.