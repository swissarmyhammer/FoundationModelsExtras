---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Add HealthStatus, HealthCheck, and the Doctorable protocol
---
## What

Add the health-check vocabulary of `doctor-plan.md` §4 (milestone D1) to the
core library. This is the base that the runner, the renderer, and every
package outside this one build on.

Make a new directory `Sources/FoundationModelsExtras/Doctor/`, beside the
`OperationEvents/` directory that is already there.

Files to create:

- `Sources/FoundationModelsExtras/Doctor/HealthCheck.swift`
  - `public enum HealthStatus: String, Sendable, Codable` with
    `case ok, warning, error`. The `String` raw value keeps the JSON stable.
  - `public struct HealthCheck: Sendable, Equatable, Codable` with the
    properties `name`, `status`, `message`, `fix: String?`, and `category`.
  - A memberwise `public init`. Keep it public: a consumer makes a check
    from data it already holds, and a test needs it.
  - Three static factory functions, which make the `fix` rule of §2 easy to
    obey at each call site:
    - `public static func ok(name:message:category:) -> HealthCheck` — sets
      `fix` to `nil`.
    - `public static func warning(name:message:fix:category:) -> HealthCheck`
      — `fix` is a non-optional `String`.
    - `public static func error(name:message:fix:category:) -> HealthCheck`
      — `fix` is a non-optional `String`.
- `Sources/FoundationModelsExtras/Doctor/Doctorable.swift`
  - `public protocol Doctorable: Sendable` with `var doctorName: String`,
    `var doctorCategory: String`, `var isApplicable: Bool`, and
  - `func runHealthChecks() async -> [HealthCheck]`.
  - An extension gives the default of `isApplicable` as `true`, and the
    default of `runHealthChecks()` as one `.ok` check. The check has the
    name `doctorName`, the category `doctorCategory`, and a message that
    tells that the component gave no check of its own.

Two contracts to write down, because a later task depends on each:

- **The factories make the `fix` rule easy, but they do not make it
  absolute.** The memberwise init stays public, and a decoder can read JSON
  that holds `"status": "warning"` and no `fix`. So a `.warning` or an
  `.error` with a `nil` fix is a value that can exist. Say so in the doc
  comment of `fix`, and point to the renderer task, which says what the
  output is in that case.
- **A `nil` fix is an absent JSON key, and not `null`.** The synthesized
  `Codable` conformance does this, because it uses `encodeIfPresent`. Do
  not hand-write `encode(to:)`, which would emit `null`.

`runHealthChecks()` returns and does not throw, per §4: a check that cannot
run is a `.error` finding with the reason in its message. One broken check
must never stop the other checks.

Write a doc comment on every public declaration, in the style of
`Sources/FoundationModelsExtras/ProcessRegistry.swift`.

## Acceptance Criteria

- [ ] `swift build` is clean, with no warning.
- [ ] A type that gives only `doctorName` and `doctorCategory` compiles, and
      `isApplicable` is `true`.
- [ ] `HealthCheck.ok(...)` gives a value whose `fix` is `nil`.
- [ ] The `warning` and the `error` factory functions take a non-optional
      `fix`, so a call site cannot leave it out.
- [ ] `HealthCheck` encodes to JSON and decodes back to an equal value.
- [ ] An encoded `.ok` check holds no `fix` key.

## Tests

- [ ] New file `Tests/FoundationModelsExtrasTests/DoctorableTests.swift`, a
      swift-testing `@Suite` with a plain `import FoundationModelsExtras`
      (no `@testable`), as `ProcessRegistryTests.swift` does.
- [ ] Test: a `Doctorable` with only `doctorName` and `doctorCategory` gives
      exactly one check, and its status is `.ok` (doctor-plan.md §8, row 1).
- [ ] Test: the default of `isApplicable` is `true`.
- [ ] Test: `HealthCheck` goes through `JSONEncoder` and `JSONDecoder` and
      stays equal, for `.ok` (no fix) and for `.error` (with a fix)
      (doctor-plan.md §8, row 7).
- [ ] Test: the encoded JSON object of an `.ok` check has **no** `fix` key,
      and the encoded object of an `.error` check **has** one. Read the keys
      with `JSONSerialization`.
- [ ] Test: `HealthStatus` encodes to the strings `"ok"`, `"warning"`, and
      `"error"`.
- [ ] Run `swift test --filter Doctor`. Expect all tests to pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.