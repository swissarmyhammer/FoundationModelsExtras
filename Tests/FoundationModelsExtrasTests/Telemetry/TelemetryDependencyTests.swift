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

    /// Gives the paths of the library sources whose text matches
    /// `isOffender`. The read of the sources must find at least one file,
    /// because a scan of no file would pass with no check.
    ///
    /// - Parameter isOffender: Tells if the text of a source breaks the rule.
    /// - Returns: The paths of the sources that break the rule, in order.
    /// - Throws: The error of a file that cannot be read.
    private static func librarySourcePaths(where isOffender: (String) -> Bool) throws -> [String] {
        let sources = try librarySources()
        #expect(!sources.isEmpty)
        return sources.filter { isOffender($0.value) }.keys.sorted()
    }

    /// Reads each package dependency URL of the manifest.
    ///
    /// - Returns: The URLs, in the order of the manifest.
    /// - Throws: A `FixtureError` when the manifest cannot be read.
    private static func dependencyURLs() throws -> [String] {
        let manifest = try FixtureFile.text(manifestPath).get()
        let packageURL = #/\.package\(\s*url:\s*"(?<url>[^"]+)"/#
        return manifest.matches(of: packageURL).map { String($0.output.url) }
    }

    /// Reads each Swift file under `Sources/`.
    ///
    /// - Returns: The text of each file, keyed by its path.
    /// - Throws: The error of a file that cannot be read.
    private static func librarySources() throws -> [String: String] {
        let root = FixtureFile.url(sourcesPath)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try Dictionary(
            uniqueKeysWithValues: files.map { ($0.path, try String(contentsOf: $0, encoding: .utf8)) }
        )
    }
}
