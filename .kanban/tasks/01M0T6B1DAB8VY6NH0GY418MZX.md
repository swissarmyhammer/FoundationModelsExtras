---
comments:
- actor: claude-code
  id: 01m0t9qrxg1knrk9a0j4v6415y
  text: |-
    Picked up. Research notes before writing code:

    - Source to port: `../FoundationModelsACPClient/Sources/FoundationModelsACPClient/ProcessRegistry.swift` (123 lines). Shape: `final class ProcessRegistry: Sendable` over `Mutex<Set<pid_t>>`, free function `sweep(_:)`, a private top-level `globalProcessRegistry`, a private `installGlobalProcessRegistrySweep()` that `atexit`s the sweep, a private `let globalProcessRegistrySweepInstalled` that Swift initializes lazily exactly one time, and `extension ProcessRegistry { static var global }` that touches that `let` and returns the registry.
    - Tests to port: `../FoundationModelsMCP/Tests/FoundationModelsMCPTests/ProcessRegistryTests.swift` (5 tests, `posix_spawn` of `/bin/sleep` in its own process group).
    - Target package style: sources carry no `//` file header; they open with imports and `///` doc comments. Indentation is 2 spaces (`swift format`). `Package.swift` needs no change: `Synchronization` is a standard-library module.
    - Validator rules that shape the port (from `dump validators`):
      - `magic-numbers-swift` (swiftlint `no_magic_numbers`, `allowed_numbers: [0, 1, -1, 100]`, no test carve-out for swift-testing suites) reports a numeric literal in a call argument or an operation. So the ported tests name `999_999` and `0x7f` instead of writing them inline.
      - `missing-docs-swift` (swiftlint `missing_docs`, `warning: [open, public]`, `excludes_trivial_init: false`) needs a doc comment on every public item, `public init()` included.
      - `duplication` — the two sweep tests share a reap-and-assert block, so it is extracted into one helper.
    - Tests use a plain `import FoundationModelsExtras`, not `@testable`, so the suite proves the API really is `public`.
  timestamp: 2026-08-24T16:30:26.736984+00:00
- actor: claude-code
  id: 01m0t9w9y7kcwd5dq627av3wd6
  text: |-
    TDD cycle, as the card asks:

    - RED: wrote `Tests/FoundationModelsExtrasTests/ProcessRegistryTests.swift` with the five ported tests and ran `swift build --build-tests`. It failed with `cannot find 'ProcessRegistry' in scope` and `cannot find 'sweep' in scope` — the feature was missing, not a typo.
    - GREEN: added `Sources/FoundationModelsExtras/ProcessRegistry.swift`, ported from the ACPClient copy with the API made `public`. `swift test --filter ProcessRegistryTests` then ran all 5 and passed.
    - Full suite: `swift test` → 219 tests in 20 suites passed. `swift build` reports no warning and no error. `swift format -i -r Sources Tests` left both new files unchanged.

    What the port changed, beside the access level:

    - The whole leading `//` block of the ACPClient copy is gone. Every sentence in it named another package. The one fact worth keeping — the registry is lock-based rather than an actor, because `register`/`deregister` must run without an `await` from the `atexit` closure — moved into the type's own `///` comment, which is where the target package's style keeps such a statement (its sources carry no `//` file header at all).
    - Every sentence that named `AgentProcess` now names the behavior instead: "the owner of a spawned process registers its pid directly after the spawn, and deregisters it after its own teardown did the group kill and the reap". The `global` doc comment keeps the honest limit word for word: `atexit` runs on a normal process exit only, never on `SIGKILL` and never on a crash.
    - `sweep(_:)` keeps its registry parameter and names `.global` nowhere in its body.

    Two deliberate differences from the MCP test file, each forced by a validator rule this package runs:

    - `999_999` is bound to `let neverRegisteredPid` and `0x7f` to `let terminatingSignalMask`. `magic-numbers-swift` (swiftlint `no_magic_numbers`) reports a numeric literal in a call argument and in an `&` operation, and its `test_parent_classes` carve-out covers `XCTestCase`/`QuickSpec` only — a swift-testing `@Suite struct` gets no carve-out.
    - The reap-and-assert-`SIGKILL` block the two sweep tests shared is one `expectKilledBySweep(_:)` helper, so the `duplication` validator has no repeated logic to report.

    `Package.swift` is untouched: `Synchronization` is a standard-library module.
  timestamp: 2026-08-24T16:32:55.239803+00:00
- actor: claude-code
  id: 01m0t9wcqrwkw5kf8ygtqwj5vb
  text: |-
    ### implement — changed
    - evidence: 3 files — /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Sources/FoundationModelsExtras/ProcessRegistry.swift (new), /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Tests/FoundationModelsExtrasTests/ProcessRegistryTests.swift (new), /Users/wballard/github/swissarmyhammer/FoundationModelsExtras/plan.md (§5 record). `swift test` → 219 tests in 20 suites passed, 0 failures, 0 warnings. All 12 checkboxes on the card are checked against the diff.
    - next: /review
  timestamp: 2026-08-24T16:32:58.104369+00:00
- actor: claude-code
  id: 01m0ta1a2vkh8ngqtna7gb2kn7
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 090e38a) — 0 findings, 0 confirmed, 0 refuted, 7 validator passes attempted, 0 failed. 2 files reviewed; 2 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to `done`. No findings section appended.
  timestamp: 2026-08-24T16:35:39.227150+00:00
- actor: claude-code
  id: 01m0ta1p1vcqtxk77x082nczjq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files: Sources/FoundationModelsExtras/ProcessRegistry.swift, Tests/FoundationModelsExtrasTests/ProcessRegistryTests.swift, plan.md
    - test: green — swift build 0 warnings, swift test 219 passed in 20 suites, 0 failed, 0 skipped
    - commit: 090e38a
    - review: clean — 0 findings, 2 files reviewed in HEAD~1..HEAD
  timestamp: 2026-08-24T16:35:51.483812+00:00
position_column: done
position_ordinal: '9780'
title: 'Add public ProcessRegistry: one home for the family''s process-group backstop'
---
## What

Four packages in the family carry their own copy of `ProcessRegistry`. The code
is the same. Remove the comments and the blank lines, and compare:

- The ACPClient copy and the MCP copy are identical, line for line.
- The Shelltool copy and the Multitool copy differ from them by one line only:
  an explicit `init() {}`.

The four copies are:

| Package | Path | Lines |
| --- | --- | --- |
| Shelltool | `../FoundationModelsShelltool/Sources/ShellTool/ProcessRegistry.swift` | 141 |
| MCP | `../FoundationModelsMCP/Sources/FoundationModelsMCP/ProcessRegistry.swift` | 149 |
| ACPClient | `../FoundationModelsACPClient/Sources/FoundationModelsACPClient/ProcessRegistry.swift` | 123 |
| Multitool | `../FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Shell/ProcessRegistry.swift` | 154 |

Each copy is `internal`, so no package can use the copy of another package.
Each package wrote a comment that says it holds a copy of the pattern.

This code stops leaked process groups. A correction to the kill path must go
into four files today, and nothing makes that happen.

This type belongs in this package. `plan.md` §1 makes this package the shared
leaf: "tool packages depend on it downward when they choose to". `plan.md` §5
sets the bar for new scope: "a demonstrated consumer on both sides of the
diamond". There are four demonstrated consumers with the same code.

The dependency budget in §5 does not change. The type needs `Foundation` and
`Synchronization` only. `Synchronization` is a standard-library module, not a
package. `Package.swift` gets no new dependency.

This task adds the type here. It does not change the four consumers. Each
consumer gets its own task after this one.

### 1. Add `Sources/FoundationModelsExtras/ProcessRegistry.swift`

Port the ACPClient copy. It is the smallest of the four, and it is identical to
the MCP copy. Make the API `public`:

- `public final class ProcessRegistry: Sendable`, with a `Mutex<Set<pid_t>>`
  behind it. Keep the lock. Do not make it an actor: `register` and
  `deregister` must run from synchronous code, and most of all from the
  `atexit` closure, which cannot `await`.
- `public init()`
- `public func register(_ pid: pid_t)`
- `public func deregister(_ pid: pid_t)`
- `public var registeredPids: Set<pid_t>`
- `public func sweep(_ registry: ProcessRegistry)`. Keep the registry
  parameter. Do not hardcode the function to `.global`. A test must be able to
  sweep a private registry, so that it never kills a pid it does not own.
- `public static var global: ProcessRegistry`. Keep the lazy `let` that
  installs the `atexit` sweep exactly one time on first access.

Keep the documentation comment that states the limit honestly: `atexit` runs on
a normal process exit only. It does not run on `SIGKILL` and it does not run on
a crash.

Change the comments in two ways:

- Delete every sentence that names another package. This package is the source
  now, so there is nothing to cite.
- Rewrite the sentences that name `AgentProcess`. That type belongs to
  ACPClient. Write the behavior in general words: the owner registers a pid
  directly after the spawn, and deregisters it after its own teardown did the
  group kill and the reap.

### 2. Record the decision in `plan.md`

§5 says "Scope fights its way in." Add a short record for this type. Give the
four consumers as the evidence. Use the same style as the Yams record in §11.

## Acceptance Criteria

- [x] `Sources/FoundationModelsExtras/ProcessRegistry.swift` exists and holds a
      `public` `ProcessRegistry`.
- [x] `register`, `deregister`, `registeredPids`, `sweep(_:)`, `init()`, and
      `static var global` are all `public`.
- [x] `sweep(_:)` takes a registry parameter. It does not reference `.global`.
- [x] `ProcessRegistry.global` returns the same instance on every access, and
      installs the `atexit` sweep one time only.
- [x] No comment in the new file names another package.
- [x] `Package.swift` has no new dependency.
- [x] `plan.md` records why this type entered the package, and names the four
      consumers.

## Tests

- [x] Add `Tests/FoundationModelsExtrasTests/ProcessRegistryTests.swift`. Port
      the five tests from
      `../FoundationModelsMCP/Tests/FoundationModelsMCPTests/ProcessRegistryTests.swift`:
      `registerThenDeregisterTracksLiveMembership`,
      `deregisteringAnUnregisteredPidIsANoOp`,
      `sweepKillsALiveChildInAPrivateRegistry`,
      `sweepToleratesAnAlreadyDeadPidAndStillKillsOtherLiveMembers`, and
      `globalRegistryIsAStableSingletonAcrossAccesses`.
- [x] The two `sweep` tests must spawn a real child process and must use a
      private `ProcessRegistry`. No test may sweep `ProcessRegistry.global`,
      because that registry can hold pids the test does not own.
- [x] Run `swift build`. It must succeed.
- [x] Run `swift test`. Every test must pass, and the five new tests must run.
- [x] The existing tests must stay green. This task adds a file and changes no
      other source.

## Workflow

- Use `/tdd`. Write the five ported tests first against the `public` API. Watch
  them fail, because the type does not exist yet. Then add the type until they
  pass.

## After this task

This task does not delete the four copies. Each consumer needs its own task to
depend on this package, import the shared type, and delete its own copy:
Shelltool, MCP, ACPClient, and Multitool. Note that ACPClient states a budget of
its own — "this package depends on the ACP wire only" — so its task must change
that rule on purpose. Use `/plan` for those four.