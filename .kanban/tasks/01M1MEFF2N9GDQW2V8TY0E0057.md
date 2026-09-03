---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1mggar3nfha1rjnkt1ze7xt
  text: |-
    Picked up. Research done.

    Context read:
    - `Sources/FoundationModelsExtras/Doctor/HealthCheck.swift` — `HealthStatus` (String raw value, `ok`/`warning`/`error`), `HealthCheck` (Sendable, Equatable, Codable) with the three factory functions `ok`/`warning`/`error`.
    - `Sources/FoundationModelsExtras/Doctor/Doctorable.swift` — protocol is `Sendable`, `isApplicable` defaults to `true`, `runHealthChecks()` returns and does not throw.
    - `doctor-plan.md` §4 (concurrent run in a task group, output keeps registration order), §5 (exit codes 0/1/5), §8 (the test table).
    - `Tests/FoundationModelsExtrasTests/DoctorableTests.swift` — the house style for this area: `@Suite` with a plain `import FoundationModelsExtras` (no `@testable`), doc comments on every private helper, `// MARK:` groups.

    Design decided:
    - `DoctorRunner.run()` enumerates `components`, keeps the registration index, filters on `isApplicable`, runs the rest in a `withTaskGroup` whose child result is `(offset, checks)`, then sorts on `offset` and flattens. The index survives the filter because `enumerated()` runs before the filter.
    - The exit codes become three named `static let` constants, so no bare number stands in the switch.
    - The `exitCode` doc comment states only that the codes come from §5, and that `1` and `5` were selected to keep the doctor codes clear of the usage codes. It makes no claim about which code a family CLI spends for a usage error (ArgumentParser exits 64, not 2).

    Test-file design (one file, `DoctorRunnerTests.swift`):
    - One `actor Signal` holding `isSignaled` plus an optional `CheckedContinuation`, so a `signal()` that lands before the `wait()` is not lost.
    - One `actor WatchdogFlag` for the `didFire` reading.
    - One stand-in component `StandInComponent` driven by a `ComponentBehavior` enum (`reportsAtOnce`, `sleeps`, `waitsFor`, `sets`), so the four scenarios need one component type and not four.
    - The concurrency test awaits `watchdog.value` after cancelling, so the flag reading is deterministic in both the concurrent case and the serial case.
  timestamp: 2026-09-03T20:48:58.115789+00:00
- actor: claude-code
  id: 01m1mgs7hrapk8ck68swavsr8f
  text: |-
    Implementation landed, by `/tdd`.

    RED first: `DoctorRunnerTests.swift` was written before either source file. `swift build --build-tests` failed with `cannot find 'DoctorRunner' in scope` and `cannot find 'DoctorReport' in scope`, which is the failure the missing feature causes.

    GREEN: `DoctorReport.swift` and `DoctorRunner.swift` were then written, and the 19 tests of `swift test --filter Doctor` pass in 0.21 s. The run ends.

    Both load-bearing tests were proved against a deliberately broken runner, so neither one passes by accident:

    1. Serial runner (`for component in components where component.isApplicable`, awaited one after the other). The concurrency test **failed** after 5.105 s with `Expectation failed: didFire == false`, and the run **ended**. It did not hang. This is the whole point of the signal-actor plus watchdog shape: a bare `withCheckedContinuation` under a `.timeLimit` trait alone would have hung here, because swift-testing enforces a time limit by cancellation and cancellation never resumes a pending continuation.
    2. Runner with the sort removed (`let ordered = collected`, so results stand in completion order). The ordering test **failed** with `Expectation failed: report.checks.map(\.name) == ["slow", "fast"]`. The slow-first, fast-second registration is what catches an append-as-it-arrives runner.

    The correct runner was restored after each experiment, and the file was read back to confirm the sort line stands.

    Notes for the next agent:
    - `components.enumerated()` runs **before** the `isApplicable` filter, on purpose. Filtering first and enumerating after would renumber the survivors, and skipping a component would then shift the ones behind it.
    - The watchdog sets its flag **before** it sets the signal, and the test awaits `watchdog.value` after cancelling. Both together make the `didFire` reading deterministic in the passing case and in the deadlocked case.
    - `swift build` is clean, with no warning. The whole suite is green: 238 + 94 + 44 + 34 + 22 tests across the five targets, zero failures.

    Discovered work, raised as ^xa5n8gg: `doctor-plan.md` §5 states "The family's Swift CLIs already use 2 for a usage error". That is wrong — these are ArgumentParser CLIs, and ArgumentParser exits 64 for a usage error. The decision §5 records (0/1/5) stays; only the reason given for it is wrong. The doc comment of `exitCode` does not repeat the claim, as this card required.
  timestamp: 2026-09-03T20:53:49.752541+00:00
- actor: claude-code
  id: 01m1mh6k35j3psng05tch6ernh
  text: |-
    Ran the gate's own lint tools against the three files, and corrected what they found.

    `swiftlint`, `swiftformat` and `periphery` are all installed on this machine, so the tool-backed rules do fire here. Two corrections came out of it:

    1. **`swift/immutability`** — `run()` first gathered the task-group results with `var results: [RegisteredFindings] = []` and a `for await ... { results.append(...) }` loop. That is the `var` accumulator the rule names word for word. It is now `await group.reduce(into: [RegisteredFindings]()) { gathered, findings in gathered.append(findings) }`. It compiles and behaves the same, and the sort on `position` still follows.

    2. **Two `// swiftlint:disable:next no_magic_numbers` directives I added were wrong and are removed.** I reasoned that `.milliseconds(200)` inside a `static let` sits in a call, where the named-constant carve-out does not reach, so I wrote the directives and a doc paragraph stating that. I then measured it instead of trusting the reasoning:
       - `static let named = Duration.milliseconds(200)` **does** report — at file scope. My reasoning about the AST was right on that point.
       - The same declaration inside a type that holds a `@Test` method reports **nothing**. This swiftlint version treats a type holding `@Test` as a test type and exempts every literal in it. The documented `test_parent_classes: ["QuickSpec", "XCTestCase"]` option is not the whole story — swift-testing is recognized as well. `import Testing` alone does not do it; the `@Test` attribute does.
       - So the directives suppressed nothing, and `superfluous_disable_command` reported both: "SwiftLint rule 'no_magic_numbers' did not trigger a violation in the disabled region; remove the disable command". A dead directive is itself a violation, and its doc paragraph made a false claim about the tool. Both are gone.

    Kept from that pass, because each stands on its own merit:
    - The three exit codes are named in the test (`passingExitCode`, `brokenExitCode`, `attentionExitCode`), written out independently of the production constants.
    - `#expect(runner.components.count == 2)` became `#expect(runner.components.map(\.doctorName) == ["off", "on"])`. This is the stronger assertion: it proves the component that does not apply keeps its place in the list, not only that two components are present.

    Verification after the corrections:
    - `swiftlint` with the gate's `no_magic_numbers`, `missing_docs`, force-operator, and 250-line length options, plus `superfluous_disable_command`: 0 violations in 3 files.
    - `swiftformat --lint` with the gate's rule roster: clean in 3 files. (`preferLazyMap` and `ifExpressions` do not exist in the installed swiftformat, so those two names were dropped from the run.)
    - `swift build`: clean, no warning.
    - `swift test --filter Doctor`: 19 tests in 2 suites pass, 0.21 s, and the run ends.
    - `swift test`: 238 + 94 + 44 + 34 + 22 tests pass across the five targets, zero failures, zero warnings.

    The serial-runner experiment was repeated after the `reduce` change, because that change touched how results are gathered: the concurrency test still **fails** after 5.276 s with `Expectation failed: didFire == false`, and the run still **ends**. The correct runner was restored and the file read back to confirm `enumerated()`, `reduce`, and the `sorted` on `position` all stand.
  timestamp: 2026-09-03T21:01:07.557341+00:00
- actor: claude-code
  id: 01m1mhbem7hnxsqt4rppv4q5xy
  text: |-
    ### implement — changed
    - evidence: 3 files — /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Sources/FoundationModelsExtras/Doctor/DoctorReport.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Sources/FoundationModelsExtras/Doctor/DoctorRunner.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Tests/FoundationModelsExtrasTests/DoctorRunnerTests.swift. `swift build` clean, no warning. `swift test --filter Doctor`: 19 tests in 2 suites passed in 0.21 s, run ended. `swift test`: 238 + 94 + 44 + 34 + 22 passed, 0 failures, 0 warnings. swiftlint and swiftformat clean on all 3 files.
    - next: `/review`
  timestamp: 2026-09-03T21:03:46.823473+00:00
depends_on:
- 01M1MEEW531GZ4EPVACAV737FR
position_column: doing
position_ordinal: '80'
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