---
comments:
- actor: claude-code
  id: 01m2x7ja3j4kz1v5zf2kfqdkj1
  text: |-
    Research (picked up):

    - `FrontmatterDocument` is a non-generic `enum` namespace that holds `split(text:)`. Swift does not permit an `enum FrontmatterDocument` and a `struct FrontmatterDocument<Metadata>` in one module. A probe in the scratchpad shows that `FrontmatterDocument.split(text:)` compiles with no generic argument when `split` is in `extension FrontmatterDocument where Metadata == Never`. Plan: make `FrontmatterDocument<Metadata: Sendable>` the `(metadata, content)` struct and keep `split` on the `Never` extension. The callers in Extras, extras-demo and FoundationModelsSkills keep the same call shape.
    - `StenciledDotfolderStack.Diagnostic` has the shape `(url, layer, message)`. The new stack needs the same shape. Plan: one shared `DotfolderStack.Diagnostic`, with `StenciledDotfolderStack.Diagnostic` as a typealias, so the two do not copy each other.
    - The only YAML text parser is `LayeredYAMLDocument.parse(_:path:)`, private, and its errors carry a path. Plan: move the Yams `Node` to `YAMLValue` conversion into `YAMLValue.parse(_:)` (path-free error), and let `LayeredYAMLDocument.parse` wrap that error with its path. The default decoder into `YAMLValue` then reuses it.
    - `StenciledDotfolderStackTests` holds a private `DiagnosticLog`. Plan: move it into a shared test file so the new tests do not copy it.
    - Test fixture: `DotfolderStackTests.Fixture` (three-layer temp tree, `write`, `makeStack`).
  timestamp: 2026-09-19T16:21:37.522914+00:00
- actor: claude-code
  id: 01m2x7zftyd6nk8q9z146ebjgp
  text: |-
    Implementation landed (TDD: the new test file and the `YAMLValue.parse` tests were written first; `swift build --build-tests` failed on the missing types; then the production code was written).

    What changed:
    - `Sources/FoundationModelsExtras/FrontmatterDocument.swift`: `FrontmatterDocument` is now `struct FrontmatterDocument<Metadata: Sendable>: Sendable` with `metadata: Metadata?` and `content: String`. `split(text:)` moved, unchanged, into `extension FrontmatterDocument where Metadata == Never`, so `FrontmatterDocument.split(text:)` compiles with no generic argument (verified from the extras-demo package, an external module). `fence` became a computed static var because a generic type cannot hold a stored static property.
    - `Sources/FoundationModelsExtras/FrontmatterDocumentStack.swift` (new): the third layer. `item`, `items(in:named:)` and `tree` split each text; the byte and directory lookups pass through. A decode failure gives `metadata == nil` plus one `DotfolderStack.Diagnostic`. `init(base:onDiagnostic:)` in `extension where Metadata == YAMLValue` is the default decoder.
    - `Sources/FoundationModelsExtras/DotfolderStacking.swift`: new shared `DotfolderStack.Diagnostic` (url, layer, message). `StenciledDotfolderStack.Diagnostic` is now a typealias to it, so the two stacks do not hold two copies of one struct. Call sites are unchanged.
    - `Sources/FoundationModelsExtras/YAMLValue.swift`: new `YAMLValue.parse(_:)` and `YAMLValueParsingError.malformed(line:message:)`. The Yams `Node` to `YAMLValue` conversion and the line extraction moved here verbatim from `LayeredYAMLDocument`.
    - `Sources/FoundationModelsExtras/LayeredYAMLDocument.swift`: `parse(_:path:)` now calls `YAMLValue.parse` and adds the path to the error. Its `import Yams` was removed because nothing in the file names a Yams type now.
    - Tests: `FrontmatterDocumentStackTests.swift` (new, 19 tests), `DiagnosticLog.swift` (new, moved out of `StenciledDotfolderStackTests` so both suites share it), four `YAMLValue.parse` tests in `YAMLValueTests.swift`.

    Discoveries:
    - Yams `Node.string` gives the scalar text for an int-tagged key too, so `1: one` parses with key `"1"`. The "mapping key is not a string scalar" branch fires for a complex key (a sequence or a mapping). The test uses `? [a, b]\n: value`.
    - `swift format lint` reports one pre-existing `UseSynthesizedInitializer` finding on `LayeredYAMLDocument.init(root:sourcesByKeyPath:)`. That line is not part of this change and was left as it was.
    - FoundationModelsSkills resolves Extras from the git `main` branch, so a local build there cannot see this working tree. Its call `FrontmatterDocument.split(text:)` has the same shape as the extras-demo call that compiles. No file in that repository was edited.

    Verification: `swift build --build-tests` 0 warnings; `swift test` green (125 + 34 + 44 + 26 + 363 tests, 0 failures); `swift build` of `Examples/ExtrasDemo` green.
  timestamp: 2026-09-19T16:28:49.374229+00:00
- actor: claude-code
  id: 01m2x7zn8ajxytwks0r5h1mxwr
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsExtras/FrontmatterDocumentStack.swift (new), Sources/FoundationModelsExtras/FrontmatterDocument.swift, Sources/FoundationModelsExtras/DotfolderStacking.swift, Sources/FoundationModelsExtras/StenciledDotfolderStack.swift, Sources/FoundationModelsExtras/YAMLValue.swift, Sources/FoundationModelsExtras/LayeredYAMLDocument.swift, Tests/FoundationModelsExtrasTests/FrontmatterDocumentStackTests.swift (new), Tests/FoundationModelsExtrasTests/DiagnosticLog.swift (new), Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift, Tests/FoundationModelsExtrasTests/YAMLValueTests.swift. `swift build --build-tests` 0 warnings; `swift test` 592 tests, 0 failures.
    - next: `/review`
  timestamp: 2026-09-19T16:28:54.922497+00:00
- actor: claude-code
  id: 01m2x838vfz4n5dpb3xg30dk4w
  text: |-
    ### test — green
    - evidence: swift build --build-tests (0 warnings); swift test — 363 tests, 29 suites, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-19T16:30:53.295339+00:00
- actor: claude-code
  id: 01m2x845180nakjagerdm4k5j4
  text: |-
    ### commit — changed
    - evidence: 376004e feat(frontmatter-stack): add FrontmatterDocumentStack for (metadata, content) items
    - next: Send the commit for review.
  timestamp: 2026-09-19T16:31:22.152341+00:00
- actor: claude-code
  id: 01m2x8a36dcxgnwfa8k3eqrn6d
  text: |-
    ### review — clean
    - evidence: 0 findings (review sha HEAD~1..HEAD, commit 376004e; 10 files reviewed, 4 files in .kanban/ skipped by .reviewignore)
    - next: none. The task is in done.
  timestamp: 2026-09-19T16:34:36.877441+00:00
- actor: claude-code
  id: 01m2x8akbczezsrwr9945r8jb3
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 files
    - test: green — swift test, 363 passed, 0 failed, 0 skipped
    - commit: 376004e
    - review: clean — 0 findings, task moved to done
  timestamp: 2026-09-19T16:34:53.420423+00:00
depends_on:
- 01M2X30BQKPD2MKA5EJQPFYMZM
- 01M2X30G7EGVT3392CZCWM3MQT
position_column: done
position_ordinal: a880
title: 'Add FrontmatterDocumentStack: the same interface, with (metadata, content) items'
---
## What

Add the third layer: `FrontmatterDocumentStack`. It has the same interface as the layers below it (card ^qpfymzm), and its `Item` is the pair (metadata, content), where the layers below give content only.

```swift
let stack = DotfolderStack(name: "myagent", workingDirectory: cwd)
let stenciled = StenciledDotfolderStack(base: stack, partialLocations: ["_partials"], variables: vars)
let documents = FrontmatterDocumentStack(base: stenciled, decode: SkillFrontmatter.decode)

documents.items(in: nil, named: "SKILL.md")   // each <id>/SKILL.md, rendered, with its metadata
```

1. **The type**: `FrontmatterDocumentStack<Base: DotfolderStacking, Metadata> where Base.Item == String`. Its `Item` is `FrontmatterDocument<Metadata>`:
   - `metadata: Metadata?` — `nil` when the file holds no frontmatter block, or when the decode failed.
   - `content: String` — the text after the closing fence, byte for byte. The full text when there is no frontmatter block.
2. **The split** uses `FrontmatterDocument.split(text:)`, which is there now. The stack holds no knowledge of YAML.
3. **The decode is given by the consumer**: `decode: (String) -> Metadata?`, applied to the raw frontmatter text. Extras gives a default decoder into `YAMLValue`, because Extras already holds Yams. `FoundationModelsSkills` gives its own decoder, which holds the lenient retry and the notes.
4. **The order of the layers is the choice of the consumer**, because each layer is generic:
   - `FrontmatterDocumentStack` over `StenciledDotfolderStack`: the whole file renders, then the split runs. The values of the frontmatter are also rendered.
   - `FrontmatterDocumentStack` over `DotfolderStack`: the split runs on the raw text. A consumer that does not want a render inside its frontmatter uses this order.
   State the difference in the documents, with the caution: a render before the split can write a character that changes the YAML. A decode failure is not an error; it gives `metadata == nil` and one diagnostic.
5. The other lookups (`data`, `size`, `exists`, `childDirectories`, `layerDirectories`) pass through to the base with no change.

## Acceptance Criteria

- [x] `FrontmatterDocumentStack` conforms to `DotfolderStacking` with `Item == FrontmatterDocument<Metadata>`.
- [x] It composes over the plain stack and over the stenciled stack, with no change of its own code.
- [x] `content` is equal to the text after the fence, byte for byte.
- [x] A file with no frontmatter gives `metadata == nil` and the full text as the content.
- [x] A decode failure gives `metadata == nil` and one diagnostic, and it does not throw.
- [x] Over the stenciled stack, a `{{ }}` in a value of the frontmatter is rendered; over the plain stack it is not.
- [x] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [x] `Tests/FoundationModelsExtrasTests/FrontmatterDocumentStackTests.swift` (new): over the plain stack, a document gives its metadata and its content, and the higher layer wins.
- [x] Same file: over the stenciled stack, a `{{ project }}` in the body and in a value of the frontmatter are both rendered.
- [x] Same file: a file with no frontmatter, and a file with an unterminated fence, each give `metadata == nil` and the full text.
- [x] Same file: a decoder that gives `nil` gives one diagnostic, and the content is still there.
- [x] Same file: `items(in: nil, named: "SKILL.md")` gives one document for each child directory that holds the file.
- [x] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay #cross-repo