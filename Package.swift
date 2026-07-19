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
            ]
        ),
    ]
)
