---
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: todo
position_ordinal: '8280'
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
- [ ] Public API matches plan.md §3 (the plan's three-argument call compiles as written); all public declarations documented
- [ ] `enumerate` results report which layer won each item
- [ ] `<NAME>_DEFAULTS_DIR` override works without rebuild (proven by test via injected environment dictionary)
- [ ] `userDirectory`/`environment` defaulted parameters are public — usable from a plain `import FoundationModelsExtras`
- [ ] Constructing a stack performs no file I/O

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift` against a fixture tree (temp dirs or `Tests/.../Fixtures/` with `defaults/`, `user/`, `project/` layers):
  - `nearest` returns the project copy when all three layers hold the file; user copy when project lacks it; defaults when only defaults has it; nil when nowhere
  - `locate` returns copies lowest → highest
  - `enumerate("commands", suffix: ".md")` shadows correctly and reports the winning layer per name
  - defaults-dir env override redirects the lowest layer
  - missing layer directories are skipped without error
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.