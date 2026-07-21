// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsExtras",
    // macOS only, per plan.md: the family's leaf package targets macOS 27+ /
    // Apple Silicon exclusively — no iOS surface is planned for any of the
    // three pillars (slash commands, `DotfolderStack`, Stencil templating).
    // `.v27` requires `PackageDescription` 6.4 (this manifest declares tools
    // 6.2, matching the sibling packages), so this falls back to `.v26` —
    // same as `FoundationModelsShelltool`'s `Package.swift` — pending a
    // tools-version bump.
    platforms: [
        .macOS(.v26),
    ],
    products: [
        // The single library product: slash-command vocabulary,
        // `DotfolderStack`, and the Stencil-backed `TemplateEngine` facade
        // (plan.md §2-4). Every consumer on both sides of the family's
        // dependency diamond links this.
        .library(name: "FoundationModelsExtras", targets: ["FoundationModelsExtras"]),
    ],
    dependencies: [
        // Templating engine for Pillar 3 (plan.md §4). PathKit rides along
        // transitively as Stencil's own dependency. Pinned `exact:` to the
        // current latest release per the dependency budget in plan.md §5:
        // Foundation + Stencil + Yams, pinned — no family imports ever.
        .package(url: "https://github.com/stencilproject/Stencil.git", exact: "0.15.1"),
        // YAML parsing for Pillar 5's `LayeredYAMLDocument` (plan.md §11).
        // Yams fought its way into the dependency budget (plan.md §5) on
        // 2026-07-21: three consumers need the identical layered-YAML
        // merge — FoundationModelsACP's `AgentConfiguration`, Shelltool's
        // `ShellPolicy`, and future Skills aggregation. No transitive
        // dependencies of its own (`CYaml` is a bundled system-library
        // target, not an external package). Pinned `exact:`, matching
        // Stencil's own pinning above.
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        // SwiftSyntax powers `DocCoverageTests`' scanner, which parses every
        // source file in `Sources/FoundationModelsExtras` and fails the build
        // on any undocumented `public` declaration. Test-only tooling —
        // declared here so the test target can link `SwiftSyntax`/
        // `SwiftParser` directly — so it does not count against the plan.md
        // §5 runtime dependency budget (Foundation + Stencil). Mirrors the
        // family's doc-coverage convention (see `FoundationModelsShelltool`).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0-latest"),
        // The thin ArgumentParser CLI driver for `Examples/ExtrasDemo`'s
        // `extras-demo` executable (plan.md §7). Declared here so the
        // example target can link `ArgumentParser` directly, but only that
        // target depends on it — the library's own dependency budget
        // (Foundation + Stencil, plan.md §5) is untouched.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        // Core library target: the slash-command types, `DotfolderStack`,
        // and the `TemplateEngine` wrap over Stencil.
        .target(
            name: "FoundationModelsExtras",
            dependencies: [
                "Stencil",
                .product(name: "Yams", package: "Yams"),
            ]
        ),

        // `Examples/ExtrasDemo` (plan.md §7): the living contract test for
        // all three pillars — a thin ArgumentParser executable with one
        // subcommand per pillar, run against a checked-in fixture tree so no
        // demo ever touches the real home directory. Kept as a target of the
        // root package (not a nested package), mirroring
        // `FoundationModelsShelltool`'s `shell-demo` example layout.
        .executableTarget(
            name: "extras-demo",
            dependencies: [
                "FoundationModelsExtras",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/ExtrasDemo/Sources/extras-demo"
        ),

        // Tests for the core library. `@testable` so the tests can reach
        // package-internal types directly.
        .testTarget(
            name: "FoundationModelsExtrasTests",
            dependencies: [
                "FoundationModelsExtras",
                // The example integration tests invoke the built
                // `extras-demo` executable as a subprocess. Declaring the
                // executable as a dependency makes `swift test` build it
                // first, so the binary is present next to the test bundle
                // for the subprocess to launch — no code from the executable
                // is imported (its `@main` entry point stays the process's,
                // not the test's). Mirrors `FoundationModelsShelltool`'s
                // `ShellToolTests` -> `shell-demo` dependency.
                "extras-demo",
                // Parse `Sources/FoundationModelsExtras` in `DocCoverageTests`
                // to fail the build on any undocumented `public` declaration.
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [
                // `CorpusGoldenTests` reads these directly off disk via
                // `PackageRootValidation.packageRoot()` (not
                // `Bundle.module`), so declaring them as resources is purely
                // to silence SwiftPM's "unhandled files" warning for the
                // non-`.swift` fixture tree living under this target's own
                // source path — the corpus, and its checked-in expected
                // output mirrors (plan.md task 9th0c05).
                .copy("Fixtures")
            ]
        ),
    ]
)
