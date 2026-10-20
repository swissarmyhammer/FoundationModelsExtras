import FixtureSupport
import Foundation
import Testing

/// The package uses the telemetry APIs only. No target depends on swift-otel,
/// and no library source bootstraps a logging or metrics backend. The
/// executables of the family bootstrap the backend.
@Suite("Telemetry dependencies: the APIs only, with no backend")
struct TelemetryDependencyTests {
    /// The text that marks a dependency on swift-otel.
    private static let otelMarker = "swift-otel"

    /// The URL of the swift-log package.
    private static let swiftLogURL = "https://github.com/apple/swift-log.git"

    /// The URL of the swift-metrics package.
    private static let swiftMetricsURL = "https://github.com/apple/swift-metrics.git"

    /// The calls that bootstrap a backend. A library source must not hold one.
    private static let backendBootstrapCalls = [
        "LoggingSystem.bootstrap",
        "MetricsSystem.bootstrap",
        "OTel.bootstrap",
    ]

    /// The texts that mark logging or signposts through the `os` framework. A
    /// library source logs through swift-log and traces through
    /// swift-distributed-tracing only.
    private static let osLoggingMarkers = [
        "os.Logger",
        "import os.log",
        "Logger(subsystem:",
        "OSSignposter",
    ]

    /// The import line of the `os` framework.
    private static let osImportLine = "import os"

    /// The logging API product.
    private static let loggingProduct = ManifestProduct(name: "Logging", package: "swift-log")

    /// The Yams product, which the core target and the marketplace target
    /// link.
    private static let yamsProduct = ManifestProduct(name: "Yams", package: "Yams")

    /// The API product of each telemetry package. A library target links the
    /// API product only. Any other product of these packages, for example a
    /// test kit or an in-memory backend, is not an API product.
    private static let telemetryAPIProducts = [
        loggingProduct,
        ManifestProduct(name: "Metrics", package: "swift-metrics"),
        PackageManifest.tracingProduct,
    ]

    /// The telemetry API products, as dependencies of a target.
    private static let telemetryAPIDependencies = Set(telemetryAPIProducts.map(TargetDependency.linking))

    /// Each dependency that the marketplace target can link: the telemetry
    /// API products, and the dependencies of the target that are not
    /// telemetry. A new dependency of the target is not in this list, thus it
    /// fails the allowlist test until a person adds it here on purpose.
    private static let marketplaceAllowlist = telemetryAPIDependencies.union([
        .byName(PackageManifest.coreTargetName),
        .linking(yamsProduct),
        .linking(PackageManifest.libgit2Product),
    ])

    /// Each dependency that the core target can link: the telemetry API
    /// products, and the dependencies of the target that are not telemetry.
    /// A new dependency of the target is not in this list, thus it fails the
    /// allowlist test until a person adds it here on purpose.
    private static let coreAllowlist = telemetryAPIDependencies.union([
        .byName("Stencil"),
        .linking(yamsProduct),
        .product(name: "ULID", package: "ULID.swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
        .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "GraphQL", package: "GraphQL"),
        .product(name: "Graphiti", package: "Graphiti"),
        .product(name: "OrderedCollections", package: "swift-collections"),
    ])

    @Test("no library source logs or writes signposts through the os framework")
    func noSourceUsesOSLogging() throws {
        let offenders = try Self.librarySourcePaths { text in
            Self.osLoggingMarkers.contains { text.contains($0) }
                || text.split(whereSeparator: \.isNewline).contains { $0 == Self.osImportLine }
        }

        #expect(offenders == [])
    }

    @Test("the manifest declares swift-log and swift-metrics")
    func theManifestDeclaresTheTelemetryAPIs() throws {
        let urls = try Self.dependencyURLs()

        #expect(urls.contains(Self.swiftLogURL))
        #expect(urls.contains(Self.swiftMetricsURL))
    }

    @Test("no dependency URL of the manifest contains swift-otel")
    func noDependencyIsSwiftOTel() throws {
        let urls = try Self.dependencyURLs()

        #expect(!urls.isEmpty)
        #expect(urls.filter { $0.contains(Self.otelMarker) } == [])
    }

    @Test("no library source bootstraps a logging, metrics or OTel backend")
    func noSourceBootstrapsABackend() throws {
        let offenders = try Self.librarySourcePaths { text in
            Self.backendBootstrapCalls.contains { text.contains($0) }
        }

        #expect(offenders == [])
    }

    @Test("the marketplace target links the logging, metrics and tracing API products")
    func theMarketplaceTargetLinksTheTelemetryAPIs() throws {
        let linked = try PackageManifest.dependencies(ofTarget: PackageManifest.marketplaceTargetName)

        #expect(Self.telemetryAPIDependencies.isSubset(of: Set(linked)))
    }

    @Test("each dependency of the marketplace target is in its allowlist: no backend, no test kit, no swift-otel")
    func theMarketplaceTargetLinksOnlyItsAllowlist() throws {
        let linked = try PackageManifest.dependencies(ofTarget: PackageManifest.marketplaceTargetName)

        #expect(!linked.isEmpty)
        #expect(Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist) == [])
    }

    @Test("each dependency of the core target is in its allowlist: no backend, no test kit, no swift-otel")
    func theCoreTargetLinksOnlyItsAllowlist() throws {
        let linked = try PackageManifest.dependencies(ofTarget: PackageManifest.coreTargetName)

        #expect(!linked.isEmpty)
        #expect(Self.unlistedDependencies(linked, allowed: Self.coreAllowlist) == [])
    }

    @Test("the allowlist check fails for a product of a telemetry package that the list does not name")
    func theCheckFailsForAnUnlistedTelemetryPackage() throws {
        let manifest = Self.marketplaceManifest(adding: #".product(name: "OTLPExporter", package: "swift-otlp-exporter")"#)

        let linked = try PackageManifest.dependencies(ofTarget: PackageManifest.marketplaceTargetName, in: manifest)

        #expect(
            Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist)
                == [.product(name: "OTLPExporter", package: "swift-otlp-exporter")])
    }

    @Test("the allowlist check fails for a product of a listed telemetry package that is not its API product")
    func theCheckFailsForANonAPIProductOfAListedPackage() throws {
        let manifest = Self.marketplaceManifest(adding: #".product(name: "InMemoryLogging", package: "swift-log")"#)

        let linked = try PackageManifest.dependencies(ofTarget: PackageManifest.marketplaceTargetName, in: manifest)

        #expect(
            Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist)
                == [.product(name: "InMemoryLogging", package: "swift-log")])
    }

    @Test("the allowlist check fails for an entry of a form that the read does not know")
    func theCheckFailsForAnUnreadEntry() throws {
        let entry = #".product(name: "Metrics", package: "swift-metrics", condition: .when(platforms: [.macOS]))"#
        let manifest = Self.marketplaceManifest(adding: entry)

        let linked = try PackageManifest.dependencies(ofTarget: PackageManifest.marketplaceTargetName, in: manifest)

        #expect(Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist) == [.unread(entry)])
    }

    @Test("no source of the marketplace target bootstraps a logging, metrics or OTel backend")
    func noMarketplaceSourceBootstrapsABackend() throws {
        let offenders = try Self.librarySourcePaths(under: PackageManifest.marketplaceSourcesPath) { text in
            Self.backendBootstrapCalls.contains { text.contains($0) }
        }

        #expect(offenders == [])
    }

    /// Gives the paths of the library sources whose text matches
    /// `isOffender`. The read of the sources must find at least one file,
    /// because a scan of no file would pass with no check.
    ///
    /// - Parameters:
    ///   - folder: The folder to read, relative to the package root. The
    ///     default is `PackageManifest.sourcesPath`, which holds each library
    ///     target.
    ///   - isOffender: Tells if the text of a source breaks the rule.
    /// - Returns: The paths of the sources that break the rule, in order.
    /// - Throws: The error of a folder or a file that cannot be read.
    private static func librarySourcePaths(
        under folder: String = PackageManifest.sourcesPath, where isOffender: (String) -> Bool
    ) throws -> [String] {
        let sources = try FixtureFile.swiftSources(under: folder)
        #expect(!sources.isEmpty)
        return sources.filter { isOffender($0.text) }.map(\.path)
    }

    /// Gives each dependency that is not in an allowlist.
    ///
    /// - Parameters:
    ///   - linked: The dependencies that a target links.
    ///   - allowed: The allowlist of the target.
    /// - Returns: The dependencies that are not in `allowed`, in the order of
    ///   `linked`.
    private static func unlistedDependencies(
        _ linked: [TargetDependency], allowed: Set<TargetDependency>
    ) -> [TargetDependency] {
        linked.filter { !allowed.contains($0) }
    }

    /// Makes the text of a manifest that declares the marketplace target with
    /// a part of its dependencies and one more entry.
    ///
    /// The list also holds a comment with a bracket and a comma, because the
    /// read must not take a comment as an entry.
    ///
    /// - Parameter entry: The entry to add, as a manifest writes it.
    /// - Returns: The text of the manifest.
    private static func marketplaceManifest(adding entry: String) -> String {
        """
        .target(
            name: "\(PackageManifest.marketplaceTargetName)",
            dependencies: [
                "\(PackageManifest.coreTargetName)",
                // A comment with a [bracket], and a comma.
                \(yamsProduct.dependencyText),
                \(loggingProduct.dependencyText),
                \(entry),
            ]
        ),
        """
    }

    /// Reads each package dependency URL of the manifest.
    ///
    /// - Returns: The URLs, in the order of the manifest.
    /// - Throws: A `FixtureError` when the manifest cannot be read.
    private static func dependencyURLs() throws -> [String] {
        let manifest = try PackageManifest.text()
        let packageURL = #/\.package\(\s*url:\s*"(?<url>[^"]+)"/#
        return manifest.matches(of: packageURL).map { String($0.output.url) }
    }
}
