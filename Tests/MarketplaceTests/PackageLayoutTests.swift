import FixtureSupport
import Testing

/// Guards the dependency limits of the package: libgit2 is a package
/// dependency of the `Marketplace` target only. The core
/// `FoundationModelsExtras` target does not depend on it, because each
/// consumer of the core target would then compile the C library from source.
/// The git fixture builder is a product that the `FoundationModelsSkills`
/// tests can import. The suite also guards that swift-distributed-tracing
/// links to the core target and to the `Marketplace` target only. The
/// `Marketplace` target links it for its telemetry, and
/// `TelemetryDependencyTests` guards that it links the API product only.
///
/// The suite reads `Package.swift` as text from the package root, through the
/// shared reads of `PackageManifest`. A manifest evaluation through
/// `swift package` starts a process and needs the toolchain; the text has the
/// same facts.
@Suite("Package layout")
struct PackageLayoutTests {
  /// The pin of the libgit2 package, as the manifest writes it.
  private static let libgit2Pin =
    #".package(url: "https://github.com/danielctull-forks/swift-libgit2.git", exact: "1.9.7")"#

  /// The dependency on the libgit2 product.
  private static let libgit2Dependency = TargetDependency.linking(PackageManifest.libgit2Product)

  /// The fixture target, which depends on the marketplace library.
  private static let fixturesTargetName = "MarketplaceFixtures"

  /// The fixture product, as the manifest writes it.
  private static let fixturesProduct =
    #".library(name: "\#(fixturesTargetName)", targets: ["\#(fixturesTargetName)"])"#

  /// The dependency on the marketplace library, which a target names by its
  /// name only.
  private static let marketplaceDependency = TargetDependency.byName(PackageManifest.marketplaceTargetName)

  /// The pin of the tracing package, as the manifest writes it.
  private static let tracingPin =
    #".package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.5.0")"#

  /// The dependency on the tracing product.
  private static let tracingDependency = TargetDependency.linking(PackageManifest.tracingProduct)

  /// The library targets other than the core target and the marketplace
  /// target. None links tracing.
  private static let otherLibraryTargetNames = ["Operations", "OperationsCLI", fixturesTargetName]

  @Test func theManifestPinsLibgit2ToTheExactVersion() throws {
    let manifest = try PackageManifest.text()

    #expect(manifest.contains(Self.libgit2Pin))
  }

  @Test func theCoreTargetDoesNotDependOnLibgit2() throws {
    let core = try PackageManifest.dependencies(ofTarget: PackageManifest.coreTargetName)

    #expect(!core.contains(Self.libgit2Dependency))
  }

  @Test func theMarketplaceTargetDependsOnLibgit2() throws {
    let marketplace = try PackageManifest.dependencies(ofTarget: PackageManifest.marketplaceTargetName)

    #expect(marketplace.contains(Self.libgit2Dependency))
  }

  @Test func marketplaceFixturesIsAProduct() throws {
    let manifest = try PackageManifest.text()

    #expect(manifest.contains(Self.fixturesProduct))
  }

  @Test func marketplaceFixturesDependsOnTheMarketplaceLibraryAndOnLibgit2() throws {
    let fixtures = try PackageManifest.dependencies(ofTarget: Self.fixturesTargetName)

    #expect(fixtures.contains(Self.marketplaceDependency))
    #expect(fixtures.contains(Self.libgit2Dependency))
  }

  @Test func theManifestPinsTracingToTheWithTracerFloor() throws {
    let manifest = try PackageManifest.text()

    #expect(manifest.contains(Self.tracingPin))
  }

  @Test func theCoreTargetDependsOnTracing() throws {
    let core = try PackageManifest.dependencies(ofTarget: PackageManifest.coreTargetName)

    #expect(core.contains(Self.tracingDependency))
  }

  @Test(arguments: otherLibraryTargetNames)
  func noOtherLibraryTargetDependsOnTracing(_ name: String) throws {
    let target = try PackageManifest.dependencies(ofTarget: name)

    #expect(!target.isEmpty)
    #expect(!target.contains(Self.tracingDependency))
  }
}
