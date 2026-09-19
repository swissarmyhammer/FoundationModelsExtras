---
depends_on:
- 01M2X30BQKPD2MKA5EJQPFYMZM
- 01M2X30G7EGVT3392CZCWM3MQT
position_column: todo
position_ordinal: '8480'
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

- [ ] `FrontmatterDocumentStack` conforms to `DotfolderStacking` with `Item == FrontmatterDocument<Metadata>`.
- [ ] It composes over the plain stack and over the stenciled stack, with no change of its own code.
- [ ] `content` is equal to the text after the fence, byte for byte.
- [ ] A file with no frontmatter gives `metadata == nil` and the full text as the content.
- [ ] A decode failure gives `metadata == nil` and one diagnostic, and it does not throw.
- [ ] Over the stenciled stack, a `{{ }}` in a value of the frontmatter is rendered; over the plain stack it is not.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/FrontmatterDocumentStackTests.swift` (new): over the plain stack, a document gives its metadata and its content, and the higher layer wins.
- [ ] Same file: over the stenciled stack, a `{{ project }}` in the body and in a value of the frontmatter are both rendered.
- [ ] Same file: a file with no frontmatter, and a file with an unterminated fence, each give `metadata == nil` and the full text.
- [ ] Same file: a decoder that gives `nil` gives one diagnostic, and the content is still there.
- [ ] Same file: `items(in: nil, named: "SKILL.md")` gives one document for each child directory that holds the file.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#dotfolder-overlay #cross-repo