---
comments:
- actor: claude-code
  id: 01kxxfqhht9d5wjzm7xegnjwg7
  text: 'Implemented TemplateEngine.swift (trusted Stencil rendering) and TemplateEngineTests.swift, TDD red/green verified. swift test: 62/62 tests pass, 0 warnings. Public API: TemplateEngine (Sendable), TemplateEngine.Trust (trusted/untrusted), TemplateEngineError (renderingFailed/untrustedRenderingNotYetImplemented) — no Stencil or PathKit type in any public signature. Precedence ladder implemented as three TemplateContext dictionaries merged lowest-first (well-known < environment < explicit context), reusing the existing internal stencilDictionary() export. Well-known values: working_directory, date (UTC yyyy-MM-dd), hostname, and dotfolder_name (derived from the DotfolderStack''s project layer directory name, present only when a stack is given) — hermetic test seam is an internal init(partials:environment:wellKnownValues:) alongside the plan-shaped public init(partials:). Untrusted trust throws TemplateEngineError.untrustedRenderingNotYetImplemented (not a trap). Running adversarial double-check next before handoff.'
  timestamp: 2026-07-19T15:25:48.474166+00:00
- actor: claude-code
  id: 01kxxfy33ryp0bctv1r6t5phk7
  text: 'Adversarial double-check (subagent_type: double-check) verdict: REVISE, one finding — the "explicitContextValueBeatsEnvironmentVariableBeatsWellKnownValueForTheSameKey" test set the environment collision on a different key ("shared_key") than the one actually rendered/asserted ("hostname"), so it never proved context beats environment on a genuine same-key collision, only context beats well-known. Fixed: environment now also sets "hostname", making it a true three-way collision on one key. Verified the fix has teeth via red-green-red: temporarily flipped the final merge closure in TemplateEngine.mergedDictionary to make the lower rung win, confirmed the test fails (asserting "from-context", got "from-env"), reverted, confirmed green again. Fresh swift test after the fix: 62/62 pass, 0 warnings. No other findings from the double-check (public API surface, Sendability, doc coverage, error-message usefulness, and DotfolderStack project-layer name derivation all checked out). Task is done and green; leaving in doing for /review.'
  timestamp: 2026-07-19T15:29:23.064028+00:00
depends_on:
- 01KXX465QV10VKCSC793TH2JX8
position_column: doing
position_ordinal: '80'
title: 'TemplateEngine: trusted Stencil rendering + variable precedence ladder'
---
## What
The Stencil wrap of plan.md §4, trusted path, no partials yet (that's the DotfolderLoader task).

- `Sources/FoundationModelsExtras/TemplateEngine.swift`: `public struct TemplateEngine: Sendable` with `init(partials: DotfolderStack?)` (nil path implemented here; the stack-backed loader lands in the follow-up task), `public enum Trust: Sendable { case trusted, untrusted }`, and `func render(_ text: String, context: TemplateContext, trust: Trust) throws -> String`. `untrusted` may `fatalError`-free stub as "not yet implemented" error until its task lands — pick a thrown error, not a trap.
- **No Stencil types in any public signature** — the facade is the whole public surface. Errors rethrown as our own error type.
- Variable precedence ladder (swissarmyhammer's, kept): explicit `TemplateContext` values > environment variables > well-known system variables (dotfolder name if a stack was given, working directory, date, hostname). Build the base dictionary lowest-first and overlay upward.
- Hermetic-test seam: engine takes an injectable environment dictionary (defaulting to `ProcessInfo.processInfo.environment`) and injectable well-known values (defaulting to real ones) so ladder tests are deterministic — keep these as defaulted parameters or an internal init so the public surface stays plan-shaped.

## Acceptance Criteria
- [x] `{{ var }}`, `{% if %}`, `{% for %}` render for trusted templates
- [x] Precedence: explicit context beats env var beats well-known, proven by tests with all three defining the same key
- [x] No Stencil or PathKit type appears in the public API (grep the public decls)
- [x] Stencil parse/render failures surface as this package's error type with useful messages

## Tests
- [x] `Tests/FoundationModelsExtrasTests/TemplateEngineTests.swift`:
  - variable substitution, `{% if %}` truthiness, `{% for x in xs %}` over an array context value
  - the three-rung precedence ladder test
  - well-known variables present when nothing overrides them
  - malformed template throws the facade error type
  - whole-file render-then-split round-trip: render a frontmatter+md document (templated YAML value in the frontmatter), then `FrontmatterDocument.split` — one rule, no per-format special cases (plan.md §4)
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.