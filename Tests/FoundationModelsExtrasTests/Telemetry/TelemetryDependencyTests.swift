import FixtureSupport
import Foundation
import Testing

/// The package uses the telemetry APIs only. No target depends on swift-otel,
/// and no library source bootstraps a logging or metrics backend. The
/// executables of the family bootstrap the backend.
@Suite("Telemetry dependencies: the APIs only, with no backend")
struct TelemetryDependencyTests {
    /// The path of the manifest, relative to the package root.
    private static let manifestPath = "Package.swift"

    /// The folder of the library sources, relative to the package root.
    private static let sourcesPath = "Sources"

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

    /// The name of the marketplace target in the manifest.
    private static let marketplaceTarget = "Marketplace"

    /// The folder of the sources of the marketplace target, relative to the
    /// package root.
    private static let marketplaceSourcesPath = "Sources/Marketplace"

    /// The name of the core target in the manifest.
    private static let coreTarget = "FoundationModelsExtras"

    /// The package of each telemetry product, and the API product of that
    /// package. A library target links the API product only. Any other
    /// product of these packages, for example a test kit or an in-memory
    /// backend, is not an API product.
    private static let telemetryAPIProducts: [String: String] = [
        "swift-log": "Logging",
        "swift-metrics": "Metrics",
        "swift-distributed-tracing": "Tracing",
    ]

    /// The telemetry API products, as dependencies of a target.
    private static let telemetryAPIDependencies = Set(
        telemetryAPIProducts.map { TargetDependency.product(name: $0.value, package: $0.key) }
    )

    /// Each dependency that the marketplace target can link: the telemetry
    /// API products, and the dependencies of the target that are not
    /// telemetry. A new dependency of the target is not in this list, thus it
    /// fails the allowlist test until a person adds it here on purpose.
    private static let marketplaceAllowlist = telemetryAPIDependencies.union([
        .byName(coreTarget),
        .product(name: "Yams", package: "Yams"),
        .product(name: "libgit2", package: "swift-libgit2"),
    ])

    /// Each dependency that the core target can link: the telemetry API
    /// products, and the dependencies of the target that are not telemetry.
    /// A new dependency of the target is not in this list, thus it fails the
    /// allowlist test until a person adds it here on purpose.
    private static let coreAllowlist = telemetryAPIDependencies.union([
        .byName("Stencil"),
        .product(name: "Yams", package: "Yams"),
        .product(name: "ULID", package: "ULID.swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
        .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ])

    /// One entry of the `dependencies` list of a target of the manifest.
    private enum TargetDependency: Hashable, CustomStringConvertible {
        /// A dependency that the manifest names with a string only: a target
        /// of the package, or a product with the name of its package.
        case byName(String)

        /// A `.product(name:package:)` dependency.
        case product(name: String, package: String)

        /// An entry of a form that the read does not know, as the manifest
        /// writes it. No allowlist holds it, thus it always fails the check.
        case unread(String)

        /// The dependency as a failed check shows it.
        var description: String {
            switch self {
            case .byName(let name): "\"\(name)\""
            case .product(let name, let package): "\(name) of \(package)"
            case .unread(let text): "unread entry \(text)"
            }
        }
    }

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
        let linked = try Self.dependencies(ofTarget: Self.marketplaceTarget, in: Self.manifestText())

        #expect(Self.telemetryAPIDependencies.isSubset(of: Set(linked)))
    }

    @Test("each dependency of the marketplace target is in its allowlist: no backend, no test kit, no swift-otel")
    func theMarketplaceTargetLinksOnlyItsAllowlist() throws {
        let linked = try Self.dependencies(ofTarget: Self.marketplaceTarget, in: Self.manifestText())

        #expect(!linked.isEmpty)
        #expect(Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist) == [])
    }

    @Test("each dependency of the core target is in its allowlist: no backend, no test kit, no swift-otel")
    func theCoreTargetLinksOnlyItsAllowlist() throws {
        let linked = try Self.dependencies(ofTarget: Self.coreTarget, in: Self.manifestText())

        #expect(!linked.isEmpty)
        #expect(Self.unlistedDependencies(linked, allowed: Self.coreAllowlist) == [])
    }

    @Test("the allowlist check fails for a product of a telemetry package that the list does not name")
    func theCheckFailsForAnUnlistedTelemetryPackage() throws {
        let manifest = Self.marketplaceManifest(adding: #".product(name: "OTLPExporter", package: "swift-otlp-exporter")"#)

        let linked = try Self.dependencies(ofTarget: Self.marketplaceTarget, in: manifest)

        #expect(
            Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist)
                == [.product(name: "OTLPExporter", package: "swift-otlp-exporter")])
    }

    @Test("the allowlist check fails for a product of a listed telemetry package that is not its API product")
    func theCheckFailsForANonAPIProductOfAListedPackage() throws {
        let manifest = Self.marketplaceManifest(adding: #".product(name: "InMemoryLogging", package: "swift-log")"#)

        let linked = try Self.dependencies(ofTarget: Self.marketplaceTarget, in: manifest)

        #expect(
            Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist)
                == [.product(name: "InMemoryLogging", package: "swift-log")])
    }

    @Test("the allowlist check fails for an entry of a form that the read does not know")
    func theCheckFailsForAnUnreadEntry() throws {
        let entry = #".product(name: "Metrics", package: "swift-metrics", condition: .when(platforms: [.macOS]))"#
        let manifest = Self.marketplaceManifest(adding: entry)

        let linked = try Self.dependencies(ofTarget: Self.marketplaceTarget, in: manifest)

        #expect(Self.unlistedDependencies(linked, allowed: Self.marketplaceAllowlist) == [.unread(entry)])
    }

    @Test("no source of the marketplace target bootstraps a logging, metrics or OTel backend")
    func noMarketplaceSourceBootstrapsABackend() throws {
        let offenders = try Self.librarySourcePaths(under: Self.marketplaceSourcesPath) { text in
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
    ///     default is ``sourcesPath``, which holds each library target.
    ///   - isOffender: Tells if the text of a source breaks the rule.
    /// - Returns: The paths of the sources that break the rule, in order.
    /// - Throws: The error of a file that cannot be read.
    private static func librarySourcePaths(
        under folder: String = sourcesPath, where isOffender: (String) -> Bool
    ) throws -> [String] {
        let sources = try librarySources(under: folder)
        #expect(!sources.isEmpty)
        return sources.filter { isOffender($0.value) }.keys.sorted()
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

    /// Reads each entry of the `dependencies` list of one target.
    ///
    /// - Parameters:
    ///   - target: The name of the target.
    ///   - manifest: The text of the manifest.
    /// - Returns: The entries, in the order of the manifest.
    /// - Throws: A failed requirement when the manifest declares no such
    ///   target.
    private static func dependencies(ofTarget target: String, in manifest: String) throws -> [TargetDependency] {
        try listEntries(ofTarget: target, in: manifest).map(dependency(of:))
    }

    /// Reads the text of each entry of the `dependencies` list of one target.
    ///
    /// The read removes each comment of the manifest first, thus a comment
    /// is never an entry. Then it takes the text after the opening bracket
    /// of the list of the `.target` declaration with the name `target`.
    ///
    /// - Parameters:
    ///   - target: The name of the target.
    ///   - manifest: The text of the manifest.
    /// - Returns: The text of each entry, with no space at its ends.
    /// - Throws: A failed requirement when the manifest declares no such
    ///   target.
    private static func listEntries(ofTarget target: String, in manifest: String) throws -> [String] {
        let stringOrComment = #/"[^"\n]*"|//[^\n]*/#
        let code = manifest.replacing(stringOrComment) { $0.output.hasPrefix("//") ? "" : $0.output }
        let declaration = try Regex(#"\.target\(\s*name:\s*"\#(target)",\s*dependencies:\s*\["#)
        let start = try #require(code.firstMatch(of: declaration))
        return topLevelEntries(of: code[start.range.upperBound...])
    }

    /// Splits the text of a list at each comma that no parenthesis and no
    /// bracket of an entry holds. The split stops at the bracket that closes
    /// the list.
    ///
    /// - Parameter list: The text after the opening bracket of the list.
    /// - Returns: The text of each entry that is not empty, with no space at
    ///   its ends.
    private static func topLevelEntries(of list: Substring) -> [String] {
        var entries = [""]
        var depth = 0
        for character in list {
            switch character {
            case "]" where depth == 0:
                return trimmed(entries)
            case "," where depth == 0:
                entries.append("")
                continue
            case "(", "[":
                depth += 1
            case ")", "]":
                depth -= 1
            default:
                break
            }
            entries[entries.count - 1].append(character)
        }
        return trimmed(entries)
    }

    /// Removes the space at the ends of each entry, and each entry that is
    /// then empty.
    ///
    /// - Parameter entries: The text of the entries.
    /// - Returns: The entries that are not empty.
    private static func trimmed(_ entries: [String]) -> [String] {
        entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Reads one entry of a `dependencies` list.
    ///
    /// - Parameter entry: The text of the entry, with no space at its ends.
    /// - Returns: The dependency, or ``TargetDependency/unread(_:)`` when the
    ///   entry has a form that the read does not know.
    private static func dependency(of entry: String) -> TargetDependency {
        if let byName = entry.wholeMatch(of: #/"(?<name>[^"]+)"/#) {
            return .byName(String(byName.output.name))
        }
        let product = #/\.product\(\s*name:\s*"(?<name>[^"]+)",\s*package:\s*"(?<package>[^"]+)"\s*\)/#
        if let match = entry.wholeMatch(of: product) {
            return .product(name: String(match.output.name), package: String(match.output.package))
        }
        return .unread(entry)
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
            name: "\(marketplaceTarget)",
            dependencies: [
                "\(coreTarget)",
                // A comment with a [bracket], and a comma.
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                \(entry),
            ]
        ),
        """
    }

    /// Reads the text of the manifest.
    ///
    /// - Returns: The text of `Package.swift`.
    /// - Throws: A `FixtureError` when the manifest cannot be read.
    private static func manifestText() throws -> String {
        try FixtureFile.text(manifestPath).get()
    }

    /// Reads each package dependency URL of the manifest.
    ///
    /// - Returns: The URLs, in the order of the manifest.
    /// - Throws: A `FixtureError` when the manifest cannot be read.
    private static func dependencyURLs() throws -> [String] {
        let manifest = try manifestText()
        let packageURL = #/\.package\(\s*url:\s*"(?<url>[^"]+)"/#
        return manifest.matches(of: packageURL).map { String($0.output.url) }
    }

    /// Reads each Swift file under one folder of the package.
    ///
    /// - Parameter folder: The folder, relative to the package root.
    /// - Returns: The text of each file, keyed by its path.
    /// - Throws: The error of a file that cannot be read.
    private static func librarySources(under folder: String) throws -> [String: String] {
        let root = FixtureFile.url(folder)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try Dictionary(
            uniqueKeysWithValues: files.map { ($0.path, try String(contentsOf: $0, encoding: .utf8)) }
        )
    }
}
