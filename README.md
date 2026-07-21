# FoundationModelsExtras

[![CI](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml)

Shared substrate for the swissarmyhammer FoundationModels family: a
cross-package slash-command vocabulary, a layered `DotfolderStack` for
locating config across defaults/user/project directories, and a
Stencil-backed `TemplateEngine` for rendering the content that lives in
them — with a whitelist-and-budget sandbox for rendering untrusted,
user-authored templates.

```swift
import FoundationModelsExtras
import Foundation

let stack = DotfolderStack(
    name: "myagent",
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
)

let engine = TemplateEngine(partials: stack)

var context = TemplateContext()
context.set(key: "name", to: .string("world"))

// `trust: .untrusted` runs a tag/filter whitelist plus include-depth,
// output-size, and iteration budgets -- for content it didn't ship itself,
// use `.trusted` for its own shipped defaults.
let greeting = try engine.render(
    "Hello {{ name }}! Config lives under .{{ dotfolder_name }}/.",
    context: context,
    trust: .untrusted
)
// greeting == "Hello world! Config lives under .myagent/."
```

## Ignoring files: `IgnoreProcessor`

`IgnoreProcessor` implements `gitignore(5)` matching semantics -- last-match-
wins, negation, anchoring, directory-only rules, and parent-directory
exclusion -- and loads rules from any file name, not just `.gitignore`.
Combine several sources with `+` (or accumulate with `+=`): the right
operand's rules are appended after the left's, so under last-match-wins
evaluation the right operand overrides the left wherever both match, the
same layering git itself applies across its own ignore sources. Every
`evaluate` call returns an `IgnoreVerdict` whose `description` explains
itself in one line, citing the deciding rule's source file and line:

```swift
let ignores =
    try IgnoreProcessor(contentsOf: gitignoreURL)
    + IgnoreProcessor(contentsOf: reviewignoreURL)

let verdict = ignores.evaluate("debug.log")
// verdict.isIgnored == true
// verdict.description == "ignored by \".gitignore\":1 `*.log`"
```

This exact sequence of calls is mirrored in
`readmeGitignoreAndReviewignoreCombinationExample` in
`Tests/FoundationModelsExtrasTests/IgnoreProcessorTests.swift`, kept green by
`swift test --filter IgnoreProcessorTests`.

## Install

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsExtras.git", branch: "main")
```

## Documentation

Design rationale -- the dependency-diamond problem this package solves, all
three pillars, and the untrusted-template sandbox's threat model -- is in
[`plan.md`](plan.md).

## License

No license file is included in this repository.
