import FixtureSupport
import Foundation
import Testing

/// Guards the dependency budget of plan.md §5 (decision 2026-09-19): libgit2
/// is a package dependency of the `Marketplace` target only. The core
/// `FoundationModelsExtras` target does not depend on it, and the git fixture
/// builder is a product that the `FoundationModelsSkills` tests can import.
///
/// The suite reads `Package.swift` as text from the package root. A manifest
/// evaluation through `swift package` starts a process and needs the
/// toolchain; the text has the same facts.
@Suite("Package layout")
struct PackageLayoutTests {
  /// The manifest, relative to the package root.
  private static let manifestPath = "Package.swift"

  /// The pin of the libgit2 package, as the manifest writes it.
  private static let libgit2Pin =
    #".package(url: "https://github.com/danielctull-forks/swift-libgit2.git", exact: "1.9.7")"#

  /// The product of the libgit2 package, as a target dependency names it.
  private static let libgit2Product = #".product(name: "libgit2", package: "swift-libgit2")"#

  /// The core target, which must not depend on libgit2.
  private static let coreTargetName = "FoundationModelsExtras"

  /// The target that carries libgit2.
  private static let marketplaceTargetName = "Marketplace"

  /// The fixture product, as the manifest writes it.
  private static let fixturesProduct = #".library(name: "MarketplaceFixtures", targets: ["MarketplaceFixtures"])"#

  /// The fixture target, which depends on the marketplace library.
  private static let fixturesTargetName = "MarketplaceFixtures"

  /// The marketplace library, as a target dependency names it.
  private static let marketplaceDependency = #""Marketplace","#

  /// The text that starts each target declaration in the manifest.
  private static let targetMarkers = [".target(", ".testTarget(", ".executableTarget(", ".macro("]

  @Test func theManifestPinsLibgit2ToTheExactVersion() throws {
    let manifest = try Self.manifest()

    #expect(manifest.contains(Self.libgit2Pin))
  }

  @Test func theCoreTargetDoesNotDependOnLibgit2() throws {
    let manifest = try Self.manifest()

    let core = try #require(Self.targetDeclaration(named: Self.coreTargetName, in: manifest))

    #expect(!core.contains(Self.libgit2Product))
  }

  @Test func theMarketplaceTargetDependsOnLibgit2() throws {
    let manifest = try Self.manifest()

    let marketplace = try #require(Self.targetDeclaration(named: Self.marketplaceTargetName, in: manifest))

    #expect(marketplace.contains(Self.libgit2Product))
  }

  @Test func marketplaceFixturesIsAProduct() throws {
    let manifest = try Self.manifest()

    #expect(manifest.contains(Self.fixturesProduct))
  }

  @Test func marketplaceFixturesDependsOnTheMarketplaceLibraryAndOnLibgit2() throws {
    let manifest = try Self.manifest()

    let fixtures = try #require(Self.targetDeclaration(named: Self.fixturesTargetName, in: manifest))

    #expect(fixtures.contains(Self.marketplaceDependency))
    #expect(fixtures.contains(Self.libgit2Product))
  }

  // MARK: - Support

  /// Reads the manifest text.
  private static func manifest() throws -> String {
    try FixtureFile.text(manifestPath).get()
  }

  /// Finds the declaration of one target in the manifest.
  ///
  /// A declaration starts at a line that holds one of ``targetMarkers`` and
  /// ends before the next such line. The products and the dependencies come
  /// before the first target, thus they are in no declaration.
  ///
  /// - Parameters:
  ///   - name: The target name.
  ///   - manifest: The manifest text.
  /// - Returns: The declaration text, or `nil` when no target has the name.
  private static func targetDeclaration(named name: String, in manifest: String) -> String? {
    targetDeclarations(in: manifest).first { $0.contains(#"name: "\#(name)""#) }
  }

  /// Splits the manifest into one text for each target declaration.
  ///
  /// - Parameter manifest: The manifest text.
  /// - Returns: The declarations, in manifest order.
  private static func targetDeclarations(in manifest: String) -> [String] {
    let lines = manifest.components(separatedBy: .newlines)
    let starts = lines.indices.filter { index in targetMarkers.contains(where: lines[index].contains) }
    let ends = starts.dropFirst() + [lines.endIndex]
    return zip(starts, ends).map { start, end in lines[start..<end].joined(separator: "\n") }
  }
}
