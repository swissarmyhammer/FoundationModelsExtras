---
depends_on:
- 01M2X30BQKPD2MKA5EJQPFYMZM
position_column: todo
position_ordinal: '8380'
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

- [ ] `StenciledDotfolderStack` conforms to `DotfolderStacking`, and each lookup gives the same file that the plain stack gives.
- [ ] `content(_:)` gives rendered text; the plain stack gives the same file unchanged.
- [ ] `item(at:)`, `items(in:named:)` and `tree(_:)` each give rendered text.
- [ ] A partial resolves from `partialLocations`, and the highest layer that holds it wins.
- [ ] A document of a `.defaults` layer renders trusted; each other layer renders untrusted, with the limits.
- [ ] A render failure gives `nil` and one diagnostic, and it does not throw.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/StenciledDotfolderStackTests.swift` (new): a body with `{{ project }}` gives the value of `variables`.
- [ ] Same file: a well-known value is available, and a value of the consumer with the same name wins.
- [ ] Same file: `{% include "header" %}` resolves from a `partialLocations` entry, and the copy of the higher layer wins.
- [ ] Same file: a body of an untrusted layer that uses a tag that is not allowed gives `nil` and one diagnostic.
- [ ] Same file: each lookup of `DotfolderStacking` gives the same files as the plain stack for the same fixture.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay #cross-repo