---
comments:
- actor: claude-code
  id: 01m2zjhjdyaddmkpb2w4e5tggh
  text: |-
    ### finish — note on the push criterion
    - The finish loop commits a local checkpoint on each iteration and never pushes. The push to `main` is the step of the user after the loop.
    - next: the user pushes `main` after this card is in `done`.
  timestamp: 2026-09-20T14:11:56.478170+00:00
- actor: claude-code
  id: 01m2zjnpmjcxzap9kz23wm32zm
  text: |-
    ### research

    Read of the code before the work starts.

    - `DotfolderStack.layers` is already a public `var`, thus `init(layers:)` only stores the list. The shim in `FoundationModelsSkills` (`Discovery/DotfolderStack+Layers.swift`) calls the derived init with the name `layers` and the root `/`, then overwrites `layers`. The new init does neither.
    - Each one-path lookup of `DotfolderStack` goes through the private `winningCopy(_:)`, which applies `isSafeRelativePath` and then `Layer.confines`. `exists(_:)` is `nearest(_:) != nil`. Thus `isExecutable(_:)` reads the URL of `nearest(_:)` and asks `FileManager.isExecutableFile`. A refused path, a symbolic link that leaves its layer root and a missing file all give `nil` from `nearest(_:)`, thus `false`.
    - `dotfolder_name` comes from `DotfolderStack.projectDotfolderName` in `TemplateEngine.swift`, a `fileprivate` computed value that takes `layers.first(where:)`. The change to `last(where:)` is one line. A derived stack holds one `.project` layer, thus its value does not change.
    - The decorators to change are `StenciledDotfolderStack` and `FrontmatterDocumentStack`. Each one holds a pass-through for `exists(_:)` already; `isExecutable(_:)` gets the same shape.
    - No type in this package other than the three stacks conforms to `DotfolderStacking`.
  timestamp: 2026-09-20T14:14:11.858387+00:00
- actor: claude-code
  id: 01m2zk69fwdmr5wrbj99ef27yh
  text: |-
    ### decisions

    Each decision of the work, with its cause.

    1. **`init(layers:)` stores the list and does nothing else.** It applies no name rule: the safe-name precondition of the derived initializer guards a name that the initializer joins onto a path, and this initializer joins nothing. It reads no file, thus a test can name a root that is not on the disk.
    2. **`isExecutable(_:)` reads the URL of `nearest(_:)` and asks `FileManager.isExecutableFile`.** It adds no check of its own, thus it gives the same answer as `exists(_:)` for a refused path, for a symbolic link that leaves its layer root, and for a missing file. It holds no special case for a directory: `exists(_:)` answers for a directory too, and a consumer that lists files reads `urls(_:)`, which holds files only.
    3. **`projectDotfolderName` in `TemplateEngine.swift` takes `layers.last(where:)`.** The layers are lowest precedence first, thus the last `.project` layer is the highest one. A derived stack holds one `.project` layer, thus its `dotfolder_name` does not change; the test `aWellKnownValueIsAvailableToTheBody` still gives `testagent`.
    4. **The execute-bit tests live in `StenciledDotfolderStackTests.swift`, as the card names.** They call the stenciled stack, which passes each call to the plain stack, and one test compares the two answers and pins the answer of the plain stack.
    5. **One test covers the mode of the file, with two files.** Two tests, one for `0o755` and one for `0o644`, would have been two bodies that differ in one constant — one function with an argument, which the duplication rule refuses. One test writes both files and reads both answers.
    6. **`DotfolderStackTests.Fixture` gained `write(_:to:in:permissions:)`.** Four tests set the mode of a file; the helper holds the one `setAttributes` call.
    7. **A test of the `Marketplace` target failed on the new changelog entry, and the test changed.** `DocumentationTests.theChangelogEntryIsTheFirstUnderUnreleased` asserted that the marketplace entry is the *first* entry under `## Unreleased`. The changelog states its own rule at the top: "The newest change is at the top." The new entry is newer, thus it takes the top and the guard was too narrow. The test is now `theChangelogHoldsTheEntryUnderUnreleased`, and it asserts that the marketplace entry is one of the entries under `## Unreleased`. The guard stands; only its over-narrow half is gone.
  timestamp: 2026-09-20T14:23:15.452791+00:00
- actor: claude-code
  id: 01m2zk6efmba1bns8k8h1c2ajw
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsExtras/DotfolderStack.swift, DotfolderStacking.swift, StenciledDotfolderStack.swift, FrontmatterDocumentStack.swift, TemplateEngine.swift; Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift, StenciledDotfolderStackTests.swift, FrontmatterDocumentStackTests.swift; Tests/MarketplaceTests/DocumentationTests.swift; CHANGELOG.md. `swift build --build-tests` gives 0 warnings and 0 errors; `swift test` gives 332 tests in 26 suites and 386 tests in 30 suites, all passed, 0 failures. The tests were written first and each one failed to compile before the code landed.
    - next: `/review`. The card is in `doing`. The commit and the push to `main` are not steps of this card.
  timestamp: 2026-09-20T14:23:20.564182+00:00
- actor: claude-code
  id: 01m2zka5ytbggpfn2dbczgj48w
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` — build complete, 0 warnings; `swift test` — 386 tests in 30 suites, 0 failed, 0 skipped
    - next: send to review
  timestamp: 2026-09-20T14:25:22.906995+00:00
- actor: claude-code
  id: 01m2zkb7f0zsp6mtsnh9x6vte8
  text: |-
    ### commit — changed
    - evidence: 62bf1aa feat(dotfolder-stack): add init(layers:) and isExecutable(_:)
    - next: The user must push the commit to main.
  timestamp: 2026-09-20T14:25:57.216145+00:00
- actor: claude-code
  id: 01m2zkhyktp5t12dxfp5j3zy8t
  text: |-
    ### review — clean
    - evidence: 0 findings
    - next: The card moves to done. The engine examined the diffs of commit 62bf1aa (`review sha HEAD~1..HEAD`), 9 files. No prior review findings were open.
  timestamp: 2026-09-20T14:29:37.530303+00:00
- actor: claude-code
  id: 01m2zkja1sta4mkzwbcsxjpv1c
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 files
    - test: green — swift test, 386 passed in 30 suites, 0 failed, 0 skipped
    - commit: 62bf1aa
    - review: clean — 0 findings, task moved to done
    - note: the push criterion stays with the user after the loop
  timestamp: 2026-09-20T14:29:49.241174+00:00
position_column: done
position_ordinal: b380
title: 'Close two DotfolderStack gaps that FoundationModelsSkills papers over: init(layers:) and the execute bit'
---
## What

The rule of the family: the raw work of loading lives here (the file system, the layers, Stencil, the frontmatter split), and a consumer keeps only the work of its own schema. `FoundationModelsSkills` still papers over two gaps of `DotfolderStack` with code of its own. Close both.

1. **A public `init(layers:)`.** `DotfolderStack` has only `init(name:workingDirectory:...)`, which derives the layers. A consumer that holds a list of layers (a host list, or the marketplace layers of `MarketplaceStore` below the local layers) cannot make a stack from it. `FoundationModelsSkills` has an internal shim for this at `../FoundationModelsSkills/Sources/FoundationModelsSkills/Discovery/DotfolderStack+Layers.swift`: it calls the derived init with the placeholder name `layers` and the root `/`, then overwrites `layers`. Add `public init(layers: [Layer])` that stores the layers and does no derivation and no I/O. **`dotfolder_name` takes the highest-precedence `.project` layer.** A derived stack has one `.project` layer, but a stack from `init(layers:)` can hold more than one: `SkillsRegistry(roots:)` of `FoundationModelsSkills` tags each root `.project`. `WellKnownValues.current(partials:)` in `TemplateEngine.swift` takes `layers.first(where:)` today; `FoundationModelsSkills` takes `layers.last(where:)`, and a test there pins it ("derives from the highest-precedence project layer"). The layers are lowest precedence first, thus the last one is correct. Change this package to `last(where:)`. A derived stack gives the same value as before. No `.project` layer gives no value.
2. **The execute bit of the winning copy.** Add `func isExecutable(_ relativePath: String) -> Bool` to `DotfolderStacking`, to `DotfolderStack`, and as a pass-through to `StenciledDotfolderStack` and `FrontmatterDocumentStack`. It answers for the winning copy, through the same path checks as `exists(_:)`. A refused path or a missing file gives `false`. `FoundationModelsSkills` needs it for the `executable` column of `list resource` and for the `chmod +x` gate of `run script`; it calls `FileManager.isExecutableFile` and `URL.resourceValues` itself today.
3. `CHANGELOG.md`: one entry under `## Unreleased`. This change adds a protocol requirement, so state that a type outside this package that conforms to `DotfolderStacking` must add the method.
4. Commit and push to `main`. `FoundationModelsSkills` names this package as a remote `main` dependency.

Do not edit `FoundationModelsSkills` in this card. Cards on that board delete the shim and the file calls after this lands.

## Acceptance Criteria

- [ ] `DotfolderStack(layers:)` is public, does no I/O, and gives the same lookups as a derived stack with the same layers.
- [ ] `dotfolder_name` comes from the last `.project` layer of the stack, and a derived stack gives the same value as before.
- [ ] `isExecutable(_:)` is a requirement of `DotfolderStacking`, and all three stacks answer it for the winning copy.
- [ ] `isExecutable(_:)` gives `false` for a path with `..`, for an absolute path, for a symbolic link that leaves its layer root, and for a missing file.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.
- [ ] The work is committed and pushed to `main` of this repository.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/DotfolderStackTests.swift`: a stack from `init(layers:)` finds the winning copy across two layers, and a marketplace layer at index 0 loses to a local layer.
- [ ] `Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift`: a stack from `init(layers:)` with two `.project` layers renders `{{ dotfolder_name }}` as the name of the second one.
- [ ] Same file: `isExecutable` is `true` for a file with mode `0755`, `false` for mode `0644`, and answers for the higher copy when two layers hold the path.
- [ ] Same file: `isExecutable` is `false` for each refused path of the list above.
- [ ] `Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift` and `FrontmatterDocumentStackTests.swift`: the decorator gives the answer of its base.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#loading-boundary #cross-repo