// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "FoundationModelsExtras",
    // macOS only, per plan.md: this package targets macOS 27+ / Apple
    // Silicon exclusively. The `.v27` enumeration case needs
    // `PackageDescription` 6.4, and this manifest declares tools 6.2, so the
    // deployment target is written in the string form, which states macOS 27
    // under tools 6.2.
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        // The core library: slash-command vocabulary, `DotfolderStack`, the
        // Stencil-backed `TemplateEngine` facade (plan.md §2-4), and the
        // operation-event vocabulary (`OperationEvents/`) that Router and the
        // `Operations` module share.
        .library(name: "FoundationModelsExtras", targets: ["FoundationModelsExtras"]),
        // The `@Operation` fusion library and its ArgumentParser CLI driver.
        // These moved here from the retired FoundationModelsOperationTool
        // package (decision 2026-08-29): one Extras package holds the
        // operation-tool capability as modules.
        .library(name: "Operations", targets: ["Operations"]),
        .library(name: "OperationsCLI", targets: ["OperationsCLI"]),
    ],
    dependencies: [
        // Templating engine for Pillar 3 (plan.md §4). PathKit rides along
        // transitively as Stencil's own dependency. Pinned `exact:` to the
        // current latest release per the dependency budget in plan.md §5.
        .package(url: "https://github.com/stencilproject/Stencil.git", exact: "0.15.1"),
        // YAML parsing for Pillar 5's `LayeredYAMLDocument` (plan.md §11).
        // Pinned `exact:`, matching Stencil's own pinning above.
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        // ArgumentParser: the `Operations` library re-exports it (macro-made
        // `Command` types conform to `ParsableCommand`), `OperationsCLI`
        // drives it, and `Examples/ExtrasDemo` links it.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // swift-syntax powers the `OperationsMacros` compiler plugin and the
        // doc-coverage tests that parse the Operations sources.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0-latest"),
        // Time-sortable identifiers for the operation-event vocabulary:
        // `ElicitationRequest.elicitationId` and
        // `ToolInvocationRecord.sessionID` are ULIDs. The library owns
        // correctness; no shim is added here.
        .package(url: "https://github.com/yaslab/ULID.swift.git", from: "1.3.1"),
    ],
    targets: [
        // Core library target: the slash-command types, `DotfolderStack`,
        // the `TemplateEngine` wrap over Stencil, and the operation-event
        // vocabulary in `OperationEvents/` (canonical home since 2026-08-29;
        // Router imports these types from here).
        .target(
            name: "FoundationModelsExtras",
            dependencies: [
                "Stencil",
                .product(name: "Yams", package: "Yams"),
                .product(name: "ULID", package: "ULID.swift"),
            ]
        ),

        // `Examples/ExtrasDemo` (plan.md §7): the living contract test for
        // all three pillars — a thin ArgumentParser executable with one
        // subcommand per pillar, run against a checked-in fixture tree so no
        // demo ever touches the real home directory.
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
                // for the subprocess to launch.
                "extras-demo",
            ],
            resources: [
                // `CorpusGoldenTests` reads these directly off disk via
                // `PackageRootValidation.packageRoot()`; declaring them as
                // resources only silences SwiftPM's "unhandled files"
                // warning for the non-`.swift` fixture tree.
                .copy("Fixtures")
            ]
        ),

        // Macro implementation target: the `@Operation` / `@OperationParam`
        // attached macros. Depends on swift-syntax to parse and synthesize
        // declarations at compile time.
        .macro(
            name: "OperationsMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        // Operations library: operation protocols, metadata, registry,
        // schema fusion, and `OperationTool`. Links the FoundationModels
        // system framework and re-exports ArgumentParser so that any target
        // applying `@Operation` (whose macro-generated `Command` types
        // conform to `ParsableCommand`) compiles without declaring its own
        // dependency on swift-argument-parser. Depends on the core module
        // for the canonical event vocabulary, which it re-exports as
        // typealiases.
        .target(
            name: "Operations",
            dependencies: [
                "OperationsMacros",
                "FoundationModelsExtras",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // ArgumentParser registry driver: assembles the noun -> verb command
        // tree from `AnyOperation` metadata at runtime.
        .target(
            name: "OperationsCLI",
            dependencies: [
                "Operations",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(
            name: "OperationsTests",
            dependencies: [
                "Operations",
                "TestSupport",
                // `DocCoverageTests.swift` parses `Sources/Operations` and
                // `Sources/OperationsCLI` with SwiftSyntax to enforce doc
                // coverage on every public declaration.
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "OperationsMacrosTests",
            dependencies: [
                "OperationsMacros",
                // `Operations` (which re-exports ArgumentParser) so
                // CommandEmissionTests.swift can, alongside its
                // assertMacroExpansion fixtures, apply `@Operation` for
                // real and compile-and-parse its generated `Command`.
                "Operations",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "OperationsCLITests",
            dependencies: ["OperationsCLI"]
        ),

        // Example: a "notes" tool exercising the full Operations stack end
        // to end — the `@Operation` macro, schema fusion, `OperationTool`
        // dispatch, and the CLI driver. Split into a library
        // (`NotesToolCore`, so its operations and `OperationTool` factory
        // are `@testable`) and a thin executable (`notes`), since SwiftPM
        // does not allow a test target to import an executable target's
        // main module.
        .target(
            name: "NotesToolCore",
            dependencies: ["Operations"],
            path: "Examples/NotesTool/Sources/NotesToolCore"
        ),
        .executableTarget(
            name: "notes",
            dependencies: ["NotesToolCore", "Operations", "OperationsCLI"],
            path: "Examples/NotesTool/Sources/notes"
        ),
        .testTarget(
            name: "NotesToolTests",
            dependencies: ["NotesToolCore", "Operations", "OperationsCLI", "TestSupport"],
            path: "Examples/NotesTool/Tests/NotesToolTests"
        ),

        // Test-only support code shared across test targets in different
        // SwiftPM modules (`OperationsTests`, `NotesToolTests`). A plain
        // library target, not a test target, since SwiftPM test targets
        // don't depend on one another — this is the standard idiom for
        // sharing test helpers across otherwise-independent test modules.
        .target(
            name: "TestSupport",
            path: "Tests/TestSupport"
        ),
    ]
)
