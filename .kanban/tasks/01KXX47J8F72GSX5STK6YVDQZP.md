---
comments:
- actor: claude-code
  id: 01kxxkkw91ggmjphf1yv66r0wm
  text: |-
    Implemented Trust.untrusted in TemplateEngine.swift: pre-render tag/filter whitelist check over lexed tokens (if/elif/else/endif/for/empty/endfor/include; zero filters), a RestrictedIncludeNode/RestrictedIncludeExtension that shadows Stencil's own include tag to enforce an include-depth limit (8) and re-validate each loaded partial's tokens, a fast literal-range reject for for-loops whose N...M span exceeds the output-size limit, and a whole-render output-size backstop (1 MiB) for cases the literal check can't see statically (e.g. context-provided collections). Path traversal / absolute-path rejection for include confirmed to already be covered by the existing DotfolderStack.isSafeRelativePath safety net (no loader change needed there), verified with dedicated tests.

    Added Tests/FoundationModelsExtrasTests/UntrustedRenderingTests.swift covering every acceptance criterion, and updated the obsolete "throws not yet implemented" test in TemplateEngineTests.swift to a real success-path test.

    swift build: clean, zero warnings. swift test: 86/86 pass in ~0.08s (including doc-coverage). Note: an early version of the output-size defense (post-hoc check only) let a huge literal for-loop range run ~11s before failing; added a static fast-reject for literal integer ranges so that case now fails instantly, keeping the whole-render check only as a backstop for data-driven cases.

    Adversarial double-check agent launched to review before handoff; will report final status once that returns.
  timestamp: 2026-07-19T16:33:42.689723+00:00
- actor: claude-code
  id: 01kxxmvvdxvr2syj8vpsawnnfq
  text: |-
    Adversarial double-check (round 1) found two real issues, both fixed:
    1. Critical: validateForLoopRange computed the literal for-loop range span with plain Int arithmetic, which traps for bounds near Int64 min/max (an attacker-controlled crash). Fixed with Int128 arithmetic; added regression tests at Int.max and Int.min...Int.max bounds.
    2. Medium: the output-size limit was only checked once, after the whole render finished, so many sibling includes (each individually under the limit) whose sum exceeded it were not caught early. Fixed with a shared, mutable OutputSizeBudget (reference type) stashed once in the Stencil Context and incremented/checked inside RestrictedIncludeNode.render after each include's own render completes.

    Round 2 double-check verified both fixes correct by manual trace of the real Stencil Context push/pop semantics, and flagged that the black-box regression test for finding 2 did not actually discriminate the fix from the pre-existing whole-render backstop (both would pass the same test). Added a white-box test (outputSizeBudgetStopsLoadingFurtherIncludesOnceTheRunningTotalExceedsTheLimit) that counts loadTemplate calls via a custom Loader and asserts fewer than all iterations ran before the throw, proving early bailout rather than eventual-only rejection. This closes the review loop per really-done's bounded-retry rule (one re-check spawned, findings fixed, no third round needed).

    Final state: swift build clean (zero warnings, confirmed on a full clean rebuild), swift test 90/90 passing in ~0.3s total (including DocCoverageTests). Leaving task in doing for /review.
  timestamp: 2026-07-19T16:55:32.541459+00:00
- actor: claude-code
  id: 01kxxnwgtrz1zszseqf1bakc2q
  text: |-
    Addressed the review finding on RestrictedIncludeNode.token. Investigated first rather than removing outright: Stencil's own NodeType protocol (Stencil/Node.swift) declares `var token: Token? { get }` as a requirement, so the property cannot be removed without breaking protocol conformance and the build. Further, Stencil's own renderNodes(_:_:) (same file), called from Template.render for the top-level node list, reads node.token via error.withToken(node.token) whenever a node's render throws, wrapping the error in a TemplateSyntaxError carrying that token's source location -- exactly the re-wrap mechanism UntrustedTemplateError's existing doc comment already described. So the property is not dead: it is protocol-mandated and genuinely read, just from Stencil's own framework code rather than from a call site in this file, which is what made it look dead on a local read/grep.

    Fix applied: expanded the doc comment on RestrictedIncludeNode.token to spell out both facts (protocol requirement + which Stencil call site reads it) so a future reader does not re-flag it. No behavior change, no new code. swift build: clean, zero warnings (verified via a from-scratch .build/debug rebuild). swift test: 90/90 pass. Marked the finding checked. Leaving in doing for /review.
  timestamp: 2026-07-19T17:13:23.032660+00:00
- actor: wballard
  id: 01kxy1wtt6m9gqd7m0cwdr54z7
  text: 'Post-done verification (double-check agent) found the output-size-bomb acceptance criterion unmet for nested `{% for %}` loops: the budget was only consumed inside includes, so nested literal ranges (each under the per-range span check) multiplied unmetered — a 500³ nest hung for minutes on the untrusted path. Fixed by replacing the untrusted `for` tag with `RestrictedForNode` (vendored from Stencil''s ForTag, MIT): a shared `IterationBudget` (100k iterations per render, nested loops multiply against it) plus per-iteration consumption of the shared `OutputSizeBudget` (double-count-safe: only bytes not already metered by nested includes/loops are added). Regression tests: nested-range iteration bomb, nested output bomb, include+literal no-double-count, and forloop/where/tuple-unpacking parity.'
  timestamp: 2026-07-19T20:43:16.166679+00:00
depends_on:
- 01KXX47408MG0KP7BAQWFKZFDW
position_column: done
position_ordinal: '8780'
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
- [x] A template using a non-whitelisted tag or filter renders trusted but throws untrusted
- [x] `{% include "../secrets.md" %}` and absolute-path includes are rejected untrusted
- [x] Include-depth bomb (self-including partial) and output-size bomb (huge `{% for %}` expansion) both terminate with descriptive errors, not hangs
- [x] Whitelisted constructs (`if`/`for`/`include`, variable substitution) work untrusted
- [x] All limits and the whitelist documented on `Trust`

## Tests
- [x] `Tests/FoundationModelsExtrasTests/UntrustedRenderingTests.swift` covering every acceptance criterion above, including the trusted-vs-untrusted contrast on the same template text
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-19 11:58)

- [x] `Sources/FoundationModelsExtras/TemplateEngine.swift:404` — The `token` property of `RestrictedIncludeNode` is stored in `init` but never read in `render` or any other method, making it dead code that will confuse readers about actual functionality. Either remove the property now and introduce it in the task that actually implements error attribution, or add an explicit forward marker comment like `// TODO: use for error attribution in the follow-up task` to clarify it as work-in-progress scaffolding. The current comment alone does not meet the carve-out standard for forward-staged infrastructure.

_Note: the engine also flagged a duplicate `canonicalize` test helper in `Tests/FoundationModelsExtrasTests/UntrustedRenderingTests.swift:10` vs. `DotfolderLoaderTests`. Dropped per the review skill's blanket test-refactor exception — fixing it requires restructuring the already-existing `DotfolderLoaderTests` helper, which is out of scope._