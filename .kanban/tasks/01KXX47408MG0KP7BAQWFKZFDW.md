---
depends_on:
- 01KXX45SJ1R0X46CBMYF59DN9K
- 01KXX46P08GEJ788SPT6GEAHEM
position_column: todo
position_ordinal: '8580'
title: 'DotfolderLoader: layered _partials/ resolution for includes'
---
## What
Wire `TemplateEngine.init(partials:)`'s non-nil path: a custom Stencil `Loader` over the stack's layered `_partials/` directories (plan.md §4).

- `Sources/FoundationModelsExtras/DotfolderLoader.swift` (internal type): implements Stencil's `Loader` protocol; resolves `{% include "name" %}` by asking the `DotfolderStack` for the nearest `_partials/<name>`, nearest layer wins. No filesystem convention of Stencil's leaks through — the stack stays the only thing touching disk.
- Name resolution must cover the swissarmyhammer corpus reality: includes there are extensionless and sometimes `_partials/`-prefixed (`{% include "_partials/coding-standards" %}`). Resolve by trying, in order: the literal name, the name with `.md` appended, and both again with a redundant leading `_partials/` stripped. Document the scheme on the loader.
- Missing partial → thrown facade error naming the include and the directories searched.

## Acceptance Criteria
- [ ] `{% include "header.md" %}` resolves through the stack; project `_partials/` shadows user shadows defaults
- [ ] Extensionless and `_partials/`-prefixed names resolve per the documented scheme
- [ ] Nested includes work (a partial including another partial)
- [ ] Missing partial produces a clear error, not a Stencil-internal one

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/DotfolderLoaderTests.swift` against a three-layer fixture tree with shadowed `_partials/`:
  - nearest-wins across layers (project shadows user shadows defaults)
  - falls through to lower layer when higher lacks the partial
  - extensionless name and `_partials/`-prefixed name both resolve
  - nested include renders
  - missing include throws the facade error with the include name in the message
- [ ] Run `swift test`; expect all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.