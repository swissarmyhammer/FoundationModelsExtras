---
depends_on:
- 01KXX465QV10VKCSC793TH2JX8
position_column: todo
position_ordinal: '8480'
title: 'TemplateEngine: trusted Stencil rendering + variable precedence ladder'
---
## What
The Stencil wrap of plan.md §4, trusted path, no partials yet (that's the DotfolderLoader task).

- `Sources/FoundationModelsExtras/TemplateEngine.swift`: `public struct TemplateEngine: Sendable` with `init(partials: DotfolderStack?)` (nil path implemented here; the stack-backed loader lands in the follow-up task), `public enum Trust: Sendable { case trusted, untrusted }`, and `func render(_ text: String, context: TemplateContext, trust: Trust) throws -> String`. `untrusted` may `fatalError`-free stub as "not yet implemented" error until its task lands — pick a thrown error, not a trap.
- **No Stencil types in any public signature** — the facade is the whole public surface. Errors rethrown as our own error type.
- Variable precedence ladder (swissarmyhammer's, kept): explicit `TemplateContext` values > environment variables > well-known system variables (dotfolder name if a stack was given, working directory, date, hostname). Build the base dictionary lowest-first and overlay upward.
- Hermetic-test seam: engine takes an injectable environment dictionary (defaulting to `ProcessInfo.processInfo.environment`) and injectable well-known values (defaulting to real ones) so ladder tests are deterministic — keep these as defaulted parameters or an internal init so the public surface stays plan-shaped.

## Acceptance Criteria
- [ ] `{{ var }}`, `{% if %}`, `{% for %}` render for trusted templates
- [ ] Precedence: explicit context beats env var beats well-known, proven by tests with all three defining the same key
- [ ] No Stencil or PathKit type appears in the public API (grep the public decls)
- [ ] Stencil parse/render failures surface as this package's error type with useful messages

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/TemplateEngineTests.swift`:
  - variable substitution, `{% if %}` truthiness, `{% for x in xs %}` over an array context value
  - the three-rung precedence ladder test
  - well-known variables present when nothing overrides them
  - malformed template throws the facade error type
  - whole-file render-then-split round-trip: render a frontmatter+md document (templated YAML value in the frontmatter), then `FrontmatterDocument.split` — one rule, no per-format special cases (plan.md §4)
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.