---
assignees:
- claude-code
position_column: done
position_ordinal: ffaa80
title: 'FrontmatterDocumentStack: the `enabled` frontmatter key and the view of the enabled documents'
---
Request from the FoundationModelsACPAgent session, for the owner. Skills (SkillsRegistry.swift:779), Agents (AgentCatalogBuilder.swift:268) and the planned Rules (plan.md:401) read their documents through FrontmatterDocumentStack. One `enabled: true|false` key here covers all three. (The request changed: a value that is not a bool fails closed, and the rule is public for a consumer with its own scan.)

## Rules
- The key is `enabled`, a YAML bool. When the key is missing, the document is enabled.
- A value that is not a bool FAILS CLOSED: the document is disabled, with one diagnostic through onDiagnostic.
- The stack reads the key from the raw frontmatter, apart from the decode of the consumer, so that each `Metadata` type gets it.
- A frontmatter that is not YAML, or not a mapping, has no key that can be read: the document is enabled. The decode diagnostic of the consumer stays as it is.
- The check runs after the layer shadowing. The nearest copy of a name wins. When that copy is off, the item is off, and a lower copy does not come back.
- A disabled document whose decode fails (for example a stub that holds only `enabled: false`) gives no decode diagnostic.
- No lock policy in Extras: a consumer decides for itself whether a built-in item can be off.

## API (additive only)
- `FrontmatterEnablement`, a public enum: `.enabled`, `.disabled`, `.invalid(String)`. `isEnabled` is false for `.invalid`. `key == "enabled"`. `init(frontmatter: String)` reads raw frontmatter text, and `init(mapping: YAMLValue?)` reads a decoded value. A consumer with its own scan (Agents) uses these.
- `FrontmatterDocument.enablement` and `isEnabled`. `init(metadata:content:enablement: = .enabled)`, so each current call of `init(metadata:content:)` still compiles.
- `FrontmatterDocumentStack.enabledItems(in:named:)` and `enabledTree(_:)` give only the enabled documents. `item(at:)`, `items` and `tree` still give each document, with its enablement.

## Tests (write them first, see them fail)
`Tests/FoundationModelsExtrasTests/FrontmatterEnabledTests.swift`
- [ ] the rule: a missing key, true, false, a value that is not a bool, a mapping that is not a dictionary, nil, and text that is not YAML
- [ ] the stack: no frontmatter and a missing key give enabled; `enabled: false` gives disabled, with a raw-String decode and with the YAMLValue decode
- [ ] a value that is not a bool gives one diagnostic, disabled, and no decode diagnostic
- [ ] a project stub with only `enabled: false` hides the defaults copy in enabledItems and enabledTree, and items still gives the stub as disabled
- [ ] the stub gives no decode diagnostic with a decode that fails on it
- [ ] malformed YAML: enabled, and only the decode diagnostic
- [ ] `FrontmatterDocument(metadata:content:)` is enabled