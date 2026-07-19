---
comments:
- actor: claude-code
  id: 01kxxbab82cj3petvdhk5mkmcc
  text: |-
    Implemented DotfolderStack in Sources/FoundationModelsExtras/DotfolderStack.swift with Layer/Located/Source types, init(name:workingDirectory:defaultsDirectory:userDirectory:environment:), nearest/locate/enumerate, and the NAME_DEFAULTS_DIR env override. Followed TDD: wrote Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift first, confirmed RED via a compile failure when the type didn't exist, then implemented to GREEN.

    Discovery worth recording: the temp-dir test fixture needed a realpath-based canonicalization step. On macOS, FileManager.default.temporaryDirectory lives under /var, which is a firmlink (not a plain symlink) to /private/var. URL.resolvingSymlinksInPath() deliberately does not cross firmlinks, but FileManager.contentsOfDirectory's results do (kernel-level resolution) — so building expected URLs from an uncanonicalized root and comparing them against enumerate()'s returned URLs failed spuriously. Fixed by canonicalizing the fixture root via POSIX realpath(3) once, after creating it, before deriving all other fixture paths from it. This is a test-fixture-only concern; DotfolderStack itself does no such resolution and doesn't need to.

    swift test: 24/24 pass across 4 suites (DotfolderStackTests, FrontmatterDocumentTests, TemplateContextTests, SmokeTests). Clean rm -rf .build && swift build also succeeds with no warnings. Adversarial double-check dispatched before handoff.
  timestamp: 2026-07-19T14:08:41.730060+00:00
- actor: claude-code
  id: 01kxxbmmwf799c6syzbk8pp6kn
  text: |-
    Adversarial double-check (via really-done) found one real defect: Layer and Located are public structs with public stored properties but no explicit public init, so Swift only synthesizes an internal memberwise init — a plain "import FoundationModelsExtras" consumer (no @testable) could not construct either type to build fixtures/fakes, even though the existing test suite never caught this since it uses @testable. Verified by hand-compiling a standalone client against the built module before the fix (got "initializer is inaccessible due to internal protection level") and after the fix (compiles and runs).

    Fix: added explicit public init(source:root:) to Layer and public init(url:layer:) to Located in Sources/FoundationModelsExtras/DotfolderStack.swift.

    Re-verified after the fix: rm -rf .build && swift build succeeds with no warnings; swift test passes 24/24 across 4 suites; standalone swiftc client against .build/debug confirms Layer/Located are now publicly constructible without @testable. No other findings from the double-check pass (layer ordering, nearest/locate/enumerate shadowing semantics, env-var override precedence, hermetic no-disk-I/O construction, and doc style all held up).

    Task is green and left in doing for /review.
  timestamp: 2026-07-19T14:14:19.279520+00:00
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: doing
position_ordinal: '80'
title: 'DotfolderStack: layered locations with source tracking'
---
## What
Implement plan.md §3 in `Sources/FoundationModelsExtras/DotfolderStack.swift` (split into a second file if it grows).

- `public struct DotfolderStack: Sendable` with `init(name:workingDirectory:defaultsDirectory:)` deriving layers in precedence order: defaults < user (`~/.<name>/`) < project (`<cwd>/.<name>/`).
- `Layer` carries its source kind (`defaults` / `user` / `project`) and root URL; `Located` carries the winning URL plus its source layer — the swissarmyhammer `FileSource` idea.
- `nearest(_:) -> URL?` (highest-precedence existing copy), `locate(_:) -> [URL]` (all existing copies, lowest → highest), `enumerate(_ subdirectory:suffix:) -> [String: Located]` (name without suffix ⇒ winning URL + layer, higher layers shadowing lower).
- Dev override: environment variable `<NAME>_DEFAULTS_DIR` (name uppercased, e.g. `MYAGENT_DEFAULTS_DIR`) repoints the defaults layer at runtime. **No compiled-in builtins** — every layer is a real directory read at runtime.
- Hermetic seam must be **publicly reachable** (the ExtrasDemo executable imports the library normally, with no `@testable` access, and must never touch the real home directory): add trailing defaulted parameters to the public init — `userDirectory: URL? = nil` (nil = derive `~/.<name>/`) and `environment: [String: String]` defaulting to `ProcessInfo.processInfo.environment`. The plan.md §3 call shape `DotfolderStack(name:workingDirectory:defaultsDirectory:)` keeps working unchanged.
- Layers whose directory does not exist are simply skipped by lookups; construction never touches disk (only `nearest`/`locate`/`enumerate` do), keeping consumers constructible in tests with no file I/O.
- Merge semantics deliberately absent — the stack locates and enumerates only; document this on the type.

## Acceptance Criteria
- [x] Public API matches plan.md §3 (the plan's three-argument call compiles as written); all public declarations documented
- [x] `enumerate` results report which layer won each item
- [x] `<NAME>_DEFAULTS_DIR` override works without rebuild (proven by test via injected environment dictionary)
- [x] `userDirectory`/`environment` defaulted parameters are public — usable from a plain `import FoundationModelsExtras`
- [x] Constructing a stack performs no file I/O

## Tests
- [x] `Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift` against a fixture tree (temp dirs or `Tests/.../Fixtures/` with `defaults/`, `user/`, `project/` layers):
  - `nearest` returns the project copy when all three layers hold the file; user copy when project lacks it; defaults when only defaults has it; nil when nowhere
  - `locate` returns copies lowest → highest
  - `enumerate("commands", suffix: ".md")` shadows correctly and reports the winning layer per name
  - defaults-dir env override redirects the lowest layer
  - missing layer directories are skipped without error
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.