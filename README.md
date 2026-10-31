# FoundationModelsExtras

[![CI](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml)

Shared parts for the swissarmyhammer FoundationModels family of Swift packages.

The package holds the code that more than one package of the family needs, so each package has one copy: a layered `DotfolderStack` that finds config in the default, user and project folders; a `TemplateEngine` with a sandbox for untrusted templates; discovery of `AGENTS.md` files; a model pool that loads each model one time; and tool hosting that runs the tools of a session in band or in the background.

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

// `.untrusted` applies a tag and filter whitelist and size limits.
// Use `.trusted` for content that the package ships itself.
let greeting = try engine.render(
    "Hello {{ name }}! Config lives under .{{ dotfolder_name }}/.",
    context: context,
    trust: .untrusted
)
// greeting == "Hello world! Config lives under .myagent/."
```

## Install

Add the package to `Package.swift`. The package needs macOS 27 and Swift 6.2.

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsExtras.git", branch: "main")
```

## Documentation

- [Reference](docs/REFERENCE.md): each type of the package, with examples.
- [Guide](docs/GUIDE.md)

## License

This repository has no license file.
