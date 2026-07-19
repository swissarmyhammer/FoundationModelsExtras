---
depends_on:
- 01KXX47408MG0KP7BAQWFKZFDW
position_column: todo
position_ordinal: '8680'
title: 'Untrusted rendering mode: restricted Environment with limits'
---
## What
Implement `Trust.untrusted` (plan.md §4): a restricted Stencil `Environment` for user/project-layer files. Stencil has no filesystem/network/exec capability of its own, so this wrapper is the whole enforcement surface — treat it that way.

- Whitelisted tags only: `if`, `for`, `include` (plus the closing/branch tags they need). Any other tag → validation error before render.
- Whitelisted filters only: start with an empty (or minimal, e.g. `default`) whitelist — the corpus survey found **zero filters** in use. Any other filter → validation error.
- Loader confined to `_partials/`: reject absolute paths and any name whose normalized path escapes `_partials/` (`..` traversal) — enforced in `DotfolderLoader` when rendering untrusted.
- Include-depth limit (e.g. 8) and rendered-output-size limit (e.g. 1 MiB) — both enforced, both named constants, both producing descriptive facade errors.
- Env vars remain *values in the context*, not an exec capability — nothing about the ladder changes between trust modes.
- Trusted mode stays unrestricted (consumer-shipped defaults).

## Acceptance Criteria
- [ ] A template using a non-whitelisted tag or filter renders trusted but throws untrusted
- [ ] `{% include "../secrets.md" %}` and absolute-path includes are rejected untrusted
- [ ] Include-depth bomb (self-including partial) and output-size bomb (huge `{% for %}` expansion) both terminate with descriptive errors, not hangs
- [ ] Whitelisted constructs (`if`/`for`/`include`, variable substitution) work untrusted
- [ ] All limits and the whitelist documented on `Trust`

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/UntrustedRenderingTests.swift` covering every acceptance criterion above, including the trusted-vs-untrusted contrast on the same template text
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.