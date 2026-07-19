---
comments:
- actor: claude-code
  id: 01kxxh3b02y9dh4b4tpz4ye65v
  text: |-
    Implemented DotfolderLoader (Sources/FoundationModelsExtras/DotfolderLoader.swift): internal Loader conformer over DotfolderStack, resolving name via literal, literal+.md, prefix stripped, stripped+.md in that order, nearest layer wins per candidate via stack.nearest("_partials/" + candidate). Missing partial throws internal DotfolderLoaderError.partialNotFound, which surfaces through TemplateEngineError.renderingFailed (no Stencil-internal type crosses the facade). Wired into TemplateEngine.render's trusted path: Environment(loader: DotfolderLoader(stack: partials)) when partials is non-nil.

    Wrote failing tests first in Tests/FoundationModelsExtrasTests/DotfolderLoaderTests.swift (RED confirmed: 6/7 new tests failed with "no loaders found" before the loader existed), then implemented to GREEN. Full suite: swift test -> 69 tests in 9 suites passed, including DocCoverageTests.

    Dispatched double-check agent for adversarial review before declaring done.
  timestamp: 2026-07-19T15:49:43.554255+00:00
- actor: claude-code
  id: 01kxxhstp7kqcd21fznz3zjx35
  text: |-
    Double-check (adversarial review) round 1 returned REVISE: DotfolderLoader was reading partial file content directly via String(contentsOf:), contradicting the "stack is the only thing that touches disk" invariant from plan.md and DotfolderStack's own doc comment. Fixed by adding DotfolderStack.content(_:) (TDD: failing test first in DotfolderStackTests.swift, then implemented) and routing DotfolderLoader.loadTemplate through stack.content(...) instead of a direct FileManager/String(contentsOf:) call. Round 2 double-check re-verified the fix and returned PASS: no direct file reads remain outside DotfolderStack, all tests green.

    Final swift test run: 71 tests in 9 suites passed (0 failures), including DotfolderLoaderTests, DotfolderStackTests (with the two new content() tests), TemplateEngineTests, and the Public API doc coverage suite.

    All acceptance criteria and subtask checkboxes verified and checked off. Leaving task in doing for /review.
  timestamp: 2026-07-19T16:02:00.519556+00:00
depends_on:
- 01KXX45SJ1R0X46CBMYF59DN9K
- 01KXX46P08GEJ788SPT6GEAHEM
position_column: done
position_ordinal: '8680'
title: 'DotfolderLoader: layered _partials/ resolution for includes'
---
## What
Wire `TemplateEngine.init(partials:)`'s non-nil path: a custom Stencil `Loader` over the stack's layered `_partials/` directories (plan.md §4).

- `Sources/FoundationModelsExtras/DotfolderLoader.swift` (internal type): implements Stencil's `Loader` protocol; resolves `{% include "name" %}` by asking the `DotfolderStack` for the nearest `_partials/<name>`, nearest layer wins. No filesystem convention of Stencil's leaks through — the stack stays the only thing touching disk.
- Name resolution must cover the swissarmyhammer corpus reality: includes there are extensionless and sometimes `_partials/`-prefixed (`{% include "_partials/coding-standards" %}`). Resolve by trying, in order: the literal name, the name with `.md` appended, and both again with a redundant leading `_partials/` stripped. Document the scheme on the loader.
- Missing partial → thrown facade error naming the include and the directories searched.

## Acceptance Criteria
- [x] `{% include "header.md" %}` resolves through the stack; project `_partials/` shadows user shadows defaults
- [x] Extensionless and `_partials/`-prefixed names resolve per the documented scheme
- [x] Nested includes work (a partial including another partial)
- [x] Missing partial produces a clear error, not a Stencil-internal one

## Tests
- [x] `Tests/FoundationModelsExtrasTests/DotfolderLoaderTests.swift` against a three-layer fixture tree with shadowed `_partials/`:
  - nearest-wins across layers (project shadows user shadows defaults)
  - falls through to lower layer when higher lacks the partial
  - extensionless name and `_partials/`-prefixed name both resolve
  - nested include renders
  - missing include throws the facade error with the include name in the message
- [x] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.