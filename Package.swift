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
        // Foundation + Stencil only, no family imports, no Yams.
        .package(url: "https://github.com/stencilproject/Stencil.git", exact: "0.15.1"),
        // SwiftSyntax powers `DocCoverageTests`' scanner, which parses every
        // source file in `Sources/FoundationModelsExtras` and fails the build
        // on any undocumented `public` declaration. Test-only tooling —
        // declared here so the test target can link `SwiftSyntax`/
        // `SwiftParser` directly — so it does not count against the plan.md
        // §5 runtime dependency budget (Foundation + Stencil). Mirrors the
        // family's doc-coverage convention (see `FoundationModelsShelltool`).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0-latest"),
    ],
    targets: [
        // Core library target: the slash-command types, `DotfolderStack`,
        // and the `TemplateEngine` wrap over Stencil.
        .target(
            name: "FoundationModelsExtras",
            dependencies: [
                "Stencil",
            ]
        ),

        // Tests for the core library. `@testable` so the tests can reach
        // package-internal types directly.
        .testTarget(
            name: "FoundationModelsExtrasTests",
            dependencies: [
                "FoundationModelsExtras",
                // Parse `Sources/FoundationModelsExtras` in `DocCoverageTests`
                // to fail the build on any undocumented `public` declaration.
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
    ]
)
