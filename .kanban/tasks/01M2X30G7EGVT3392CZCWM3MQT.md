---
comments:
- actor: claude-code
  id: 01m2x6f96whajd0h3nt189cmv7
  text: |-
    Research (implement step):

    - `DotfolderStacking` (Sources/FoundationModelsExtras/DotfolderStacking.swift) has `layers`, `item(at:)`, `items(in:named:)`, `tree(_:)`, `childDirectories(of:)`, `layerDirectories(_:)`, `data(_:)`, `data(_:in:)`, `size(of:)`, `exists(_:)`. `content(_:)` is a method of `DotfolderStack` only, not of the protocol.
    - `TemplateEngine` (TemplateEngine.swift) has a public `init(partials:)` that reads the process environment and the well-known values, and an internal init `init(partials:environment:wellKnownValues:)`. `render(_:context:trust:)` throws `TemplateEngineError`. The untrusted path applies the tag whitelist, the include depth, the output size and the loop count.
    - `DotfolderLoader` (DotfolderLoader.swift, internal) resolves an include only in `_partials/`. The location is a fixed string. It needs a `partialLocations` parameter.
    - `WellKnownValues.current(partials:)` gives `working_directory`, `date`, `hostname` and `dotfolder_name` (from the `.project` layer of the stack).
    - The scope rule to move is `StencilPass.partialsStack(for:)` in FoundationModelsSkills: local layers are the layers that are not `.marketplace`; a `.marketplace` document gets `[winningLayer] + localLayers`; a local document gets the local layers only. The trust rule is `layer.source == .defaults ? .trusted : .untrusted`.
    - Tests collect from a `@Sendable` closure with a `final class` around a `Mutex` (ExtrasDemoIntegrationTests.swift, `StreamBuffer`).
    - Toolchain: Swift 6.4, macOS 27. No `.swift-format` config in the repo.

    Plan: new `Sources/FoundationModelsExtras/StenciledDotfolderStack.swift`; `DotfolderLoader` gets `partialLocations`; `TemplateEngine` gets `partialLocations` through its internal init; new `Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift`.
  timestamp: 2026-09-19T16:02:29.724038+00:00
- actor: claude-code
  id: 01m2x6rta9gjfhj3b4c44cvmf9
  text: |-
    Implementation landed (TDD):

    - RED: `Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift` (24 tests) failed with `cannot find type 'StenciledDotfolderStack' in scope`.
    - GREEN: `Sources/FoundationModelsExtras/StenciledDotfolderStack.swift` (new), `DotfolderLoader.swift` (partial locations, layer-major search), `TemplateEngine.swift` (`partialLocations` through the internal init, one `makeLoader()` for both trust paths).
    - `swift build --build-tests`: 0 warnings. `swift test`: 340 tests in 28 suites pass, 0 failures. `swift format lint -s` is clean on the new and changed files; the one `.forEach` finding in `TemplateEngine.swift` is in vendored code that this task did not touch.

    Decisions:
    - The process environment is not a rung of the stenciled stack. The card names only `variables` above the well-known values, so the stack calls the internal `TemplateEngine` init with an empty environment. A consumer puts an environment value in `variables` when it wants one.
    - `DotfolderLoader` now searches layer by layer, highest first, and inside one layer each partial location and each name variant. Thus the highest layer that holds the partial wins across locations, as the card says. With the default single location the result is the same as before.
    - The scope rule of `StencilPass.partialsStack(for:)` is now `StenciledDotfolderStack.partialsStack(for:)`. FoundationModelsSkills is not edited; card ^95get removes the copy there.
    - The well-known values are derived once at construction from the base stack (`dotfolder_name` from its `.project` layer), the same as `TemplateEngine.init(partials:)`.
  timestamp: 2026-09-19T16:07:42.153051+00:00
- actor: claude-code
  id: 01m2x6z5k2t9y92m24rmb9y2x0
  text: |-
    Rule check against the review validators (code-hygiene, code-security, completeness, duplication, reuse, swift, test-integrity), with the corrections made:

    - immutability: `DotfolderLoader.candidateNames(for:)` built its result with a `var` accumulator. It now builds it with `compactMap` and `flatMap`.
    - reuse: `StenciledDotfolderStack.makeContext(from:)` did what `TemplateEngine.buildContext(from:)` did. Both are removed. `TemplateContext` has an internal `init(values:)` that both types call.
    - initialization (init does no slow work): the stack read `WellKnownValues.current(partials:)` at construction, which reads the hostname. It now reads them at the time of each render, thus `date` is the date of the render.
    - magic-numbers-swift: the test `0..<4` is now the named constant `leadingBytes`.
    - concurrency: the test `DiagnosticLog` states why it is a lock and not an actor (the hook is synchronous).

    After the corrections: `swift build --build-tests` 0 warnings; `swift format lint -s` clean on the new and changed files; `swift test` 340 tests in 28 suites, 0 failures.

    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/StenciledDotfolderStack.swift (new), Sources/FoundationModelsExtras/DotfolderLoader.swift, Sources/FoundationModelsExtras/TemplateEngine.swift, Sources/FoundationModelsExtras/TemplateContext.swift, Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift (new, 24 tests); swift test: 340 tests, 0 failures, 0 warnings
    - next: /review
  timestamp: 2026-09-19T16:11:10.306096+00:00
- actor: claude-code
  id: 01m2x72regbeaswde62spg6q4c
  text: |-
    ### test — green
    - evidence: swift build --build-tests (clean rebuild) — 0 warnings, build OK; swift test — 340 tests in 28 suites, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-19T16:13:07.920948+00:00
- actor: claude-code
  id: 01m2x73vy517pw8rq5s9z8wp5m
  text: |-
    ### commit — changed
    - evidence: 4c1bb03 feat(dotfolder-stack): add StenciledDotfolderStack with partial locations and variables
    - next: ready for review
  timestamp: 2026-09-19T16:13:44.261907+00:00
- actor: claude-code
  id: 01m2x799en0vxyxk7xpttxsnfh
  text: |-
    ### review — clean
    - evidence: 0 findings — `review sha HEAD~1..HEAD` (commit 4c1bb03), 5 files reviewed, 7 validator passes attempted, 0 failed
    - next: none — the task is in `done`
  timestamp: 2026-09-19T16:16:41.941135+00:00
- actor: claude-code
  id: 01m2x79s45vpt3js7qsnthy8nd
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files
    - test: green — swift test, 340 passed, 0 failed, 0 skipped
    - commit: 4c1bb03
    - review: clean — 0 findings, task moved to done
  timestamp: 2026-09-19T16:16:57.989265+00:00
depends_on:
- 01M2X30BQKPD2MKA5EJQPFYMZM
position_column: done
position_ordinal: a780
title: 'Add StenciledDotfolderStack: the same interface, with partial locations and variables'
---
## What

Add `StenciledDotfolderStack`: the same interface as `DotfolderStack` (`DotfolderStacking`, card ^qpfymzm), with one difference — each text that it gives back is rendered with Stencil first.

A consumer picks the implementation and then uses the same calls. It never names Stencil, it never names the trust, and it never assembles the render itself.

```swift
let stack = DotfolderStack(name: "myagent", workingDirectory: cwd)
let stenciled = StenciledDotfolderStack(
    base: stack,
    partialLocations: ["_partials"],
    variables: ["project": "acme", "ARGUMENTS": "one two"])

stenciled.content("review/SKILL.md")          // rendered text
stenciled.items(in: nil, named: "SKILL.md")   // each <id>/SKILL.md, rendered
```

1. **The two new inputs.**
   - `partialLocations: [String]` — the directories, relative to a layer root, where a `{% include %}` can find a partial. The search follows the combined view: the highest layer that holds the partial wins. The default is `["_partials"]`, which is the behavior of `DotfolderLoader` now.
   - `variables: [String: String]` — the values that the render interpolates. The consumer gives them; the stack adds the well-known values (`working_directory`, `date`, `hostname`, `dotfolder_name`) below them, thus a value of the consumer wins.
2. **What is rendered.** Its `Item` is `String`, the same as the plain stack. Each text that a lookup gives back is rendered: `content(_:)`, `item(at:)`, `items(in:named:)` and `tree(_:)`. The frontmatter is not a concept at this layer; the card ^9ta9smb gives the layer that splits it, and the consumer chooses the order of the two.
3. **The trust comes from the layer**, not from the caller: `.defaults` is trusted, each other layer is untrusted, with the limits of the untrusted path that `TemplateEngine` applies now (allowed tags, no filters, the include depth, the output size, the loop count). A caller cannot name the trust.
4. **The scope of the partials** is the layer of the document plus the local layers, which is the rule that `FoundationModelsSkills` applies now in `StencilPass.partialsStack(for:)`. Move that rule here.
5. **A render failure does not throw out of a lookup.** a lookup gives `nil` when the render fails, and the failure text is given through a diagnostic hook that the caller can read, for example a closure on the initializer.
6. The construction does no I/O, the same as `DotfolderStack`. A caller can make a stenciled stack for each call, with the variables of that call.

## Acceptance Criteria

- [x] `StenciledDotfolderStack` conforms to `DotfolderStacking`, and each lookup gives the same file that the plain stack gives.
- [x] `content(_:)` gives rendered text; the plain stack gives the same file unchanged.
- [x] `item(at:)`, `items(in:named:)` and `tree(_:)` each give rendered text.
- [x] A partial resolves from `partialLocations`, and the highest layer that holds it wins.
- [x] A document of a `.defaults` layer renders trusted; each other layer renders untrusted, with the limits.
- [x] A render failure gives `nil` and one diagnostic, and it does not throw.
- [x] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [x] `Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift` (new): a body with `{{ project }}` gives the value of `variables`.
- [x] Same file: a well-known value is available, and a value of the consumer with the same name wins.
- [x] Same file: `{% include "header" %}` resolves from a `partialLocations` entry, and the copy of the higher layer wins.
- [x] Same file: a body of an untrusted layer that uses a tag that is not allowed gives `nil` and one diagnostic.
- [x] Same file: each lookup of `DotfolderStacking` gives the same files as the plain stack for the same fixture.
- [x] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay #cross-repo