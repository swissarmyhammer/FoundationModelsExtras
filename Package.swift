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
        // The marketplace pillar (decision 2026-09-19): Extras owns all
        // marketplace file reading, thus the git transport, the catalog read,
        // the cache, the snapshot write and the config load live here.
        // libgit2 is a real package dependency, so it lands on this separate
        // target and not on the core target, the same way `Operations`
        // carries swift-syntax without pushing it onto the core target.
        .library(name: "Marketplace", targets: ["Marketplace"]),
        // The git fixture builder that both this package's tests and the
        // `FoundationModelsSkills` tests use, so there is one copy
        // (decision 2026-09-19).
        .library(name: "MarketplaceFixtures", targets: ["MarketplaceFixtures"]),
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
        // libgit2 for the `Marketplace` target only (decision 2026-09-19):
        // marketplace git sources go through libgit2, never the `git` binary.
        // libgit2 compiles from C source as a SwiftPM target, so there is no
        // binary artifact and no system dependency. Pinned `exact:` to the
        // same version that `FoundationModelsSkills` pins, in the same style
        // as the Yams pin. The core target does not depend on it.
        .package(url: "https://github.com/danielctull-forks/swift-libgit2.git", exact: "1.9.7"),
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
                // The ignore-parity suites read the checked-in fixtures and
                // the recorded `git check-ignore` snapshots through this
                // module, which `record-git-parity-snapshots` writes them
                // with. One module owns the fixture format, so the test and
                // the recorder cannot drift.
                "FixtureSupport",
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

        // Fixture support shared between a test target and a tool, which is
        // why it is a plain library target rather than test-target code: a
        // SwiftPM executable cannot import a test target, and a standalone
        // `swift <file>.swift` script cannot import any target at all. It
        // owns the one copy of `URL.canonicalDirectory`, the checked-in
        // fixture reader, the recorded git-verdict format, and the
        // `IgnoreParitySuite` table that names every probe.
        .target(
            name: "FixtureSupport",
            path: "Tests/FixtureSupport"
        ),

        // Marketplace library (decision 2026-09-19): the git transport over
        // libgit2 and the read of a fetched commit tree, moved here from
        // `FoundationModelsSkills`. Depends on the core module for the
        // dotfolder stack that the config loader of a later card reads, and
        // on Yams because that loader encodes and decodes `marketplaces.yaml`
        // with Yams. The core target keeps its rule that Yams stays inside
        // `YAMLValue.swift`; this target is not the core target.
        .target(
            name: "Marketplace",
            dependencies: [
                "FoundationModelsExtras",
                .product(name: "Yams", package: "Yams"),
                // The C API behind `LibGit2Transport`: the remote head, the
                // shallow fetch, and the tree read of a marketplace.
                .product(name: "libgit2", package: "swift-libgit2"),
            ]
        ),

        // The test doubles and the fixture builders of the marketplace
        // (decision 2026-09-19): `GitFixtureRepository`, a bare repository
        // that a test builds with libgit2 only, with no `git` binary and no
        // network, and `RecordingGitTransport`, the counting double that a
        // store test injects. A plain library target and a product, not
        // test-target code, so that both `MarketplaceTests` here and the
        // `FoundationModelsSkills` tests import the one copy, and a consumer
        // test target links libgit2 through it. Depends on `Marketplace` for
        // the public `GitTransport` that the double conforms to, on
        // `FixtureSupport` for its temporary directory, and on libgit2 for
        // the repository build.
        .target(
            name: "MarketplaceFixtures",
            dependencies: [
                "Marketplace",
                "FixtureSupport",
                .product(name: "libgit2", package: "swift-libgit2"),
            ],
            path: "Tests/MarketplaceFixtures"
        ),

        // Tests for the marketplace library. `@testable` so the tests can
        // reach the internal credential gate, the tree file source, and the
        // error mapping of the libgit2 transport.
        .testTarget(
            name: "MarketplaceTests",
            dependencies: [
                "Marketplace",
                // `PackageLayoutTests` and `NoGitProcessTests` read files off
                // the package root through `FixtureFile.packageRoot`, and the
                // transport tests make temporary directories through
                // `TemporaryDirectory`.
                "FixtureSupport",
                // The transport tests fetch from repositories that
                // `GitFixtureRepository` builds.
                "MarketplaceFixtures",
            ]
        ),

        // Records the ignore-parity snapshots the test suite compares
        // against. Run it with `swift run record-git-parity-snapshots` after
        // a git upgrade, and read the diff. It is the only place in the
        // project that starts a `git` process for ignore parity; `swift test`
        // starts none.
        .executableTarget(
            name: "record-git-parity-snapshots",
            dependencies: ["FixtureSupport"],
            path: "Scripts/RecordGitParitySnapshots"
        ),
    ]
)
