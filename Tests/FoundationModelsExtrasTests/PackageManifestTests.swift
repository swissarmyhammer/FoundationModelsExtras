import FixtureSupport
import Foundation
import Testing

/// Proves the shared readers of `FixtureSupport` that the manifest suites and
/// the source suites of more than one test target call: the read of the
/// manifest text, the read of the `dependencies` list of a target, and the
/// read of the Swift sources under a folder.
@Suite("Package manifest and source readers")
struct PackageManifestTests {
  /// The folder of the fixture support sources, relative to the package root.
  private static let fixtureSupportPath = "Tests/FixtureSupport"

  /// The name of the file that declares ``PackageManifest``.
  private static let manifestNamesFileName = "PackageManifest.swift"

  /// The path of the file that declares ``PackageManifest``.
  private static let manifestNamesPath = "\(fixtureSupportPath)/\(manifestNamesFileName)"

  /// A folder that the package does not hold.
  private static let missingFolder = "Tests/NoSuchFolder"

  /// A target name that the manifest does not declare.
  private static let missingTarget = "NoSuchTarget"

  /// The target of the sample manifest.
  private static let sampleTarget = "Sample"

  /// A target of the package that the sample target names by its name only.
  private static let sampleLocalTarget = "Local"

  /// A product that the sample target links.
  private static let sampleProduct = ManifestProduct(name: "SampleProduct", package: "sample-package")

  /// An entry with a condition, which is a form that the read does not know.
  private static let sampleConditionalEntry =
    #".product(name: "ConditionalProduct", package: "sample-package", condition: .when(platforms: [.linux]))"#

  @Test func theManifestTextDeclaresThePackage() throws {
    let text = try PackageManifest.text()

    #expect(text.contains("let package = Package("))
  }

  @Test func theReadGivesEachEntryOfTheListOfATarget() throws {
    let manifest = """
      .target(
          name: "\(Self.sampleTarget)",
          dependencies: [
              "\(Self.sampleLocalTarget)",
              // A comment with a [bracket], and a comma.
              \(Self.sampleProduct.dependencyText),
              \(Self.sampleConditionalEntry),
          ]
      ),
      """

    let entries = try PackageManifest.dependencies(ofTarget: Self.sampleTarget, in: manifest)

    #expect(
      entries == [
        .byName(Self.sampleLocalTarget),
        .linking(Self.sampleProduct),
        .unread(Self.sampleConditionalEntry),
      ])
  }

  @Test func theReadOfTheRealManifestFindsTheCoreTarget() throws {
    let entries = try PackageManifest.dependencies(ofTarget: PackageManifest.coreTargetName)

    #expect(entries.contains(.linking(PackageManifest.tracingProduct)))
  }

  @Test func theReadThrowsForATargetThatTheManifestDoesNotDeclare() {
    #expect(throws: FixtureError.self) {
      try PackageManifest.dependencies(ofTarget: Self.missingTarget)
    }
  }

  @Test func theSourceReadGivesEachSwiftFileWithItsPathFromThePackageRoot() throws {
    let sources = try FixtureFile.swiftSources(under: Self.fixtureSupportPath)

    let manifestNames = try #require(sources.first { $0.path == Self.manifestNamesPath })
    #expect(manifestNames.name == Self.manifestNamesFileName)
    #expect(manifestNames.text.contains("public enum PackageManifest"))
    #expect(sources.allSatisfy { $0.path.hasPrefix("\(Self.fixtureSupportPath)/") && $0.path.hasSuffix(".swift") })
    #expect(sources.map(\.path) == sources.map(\.path).sorted())
  }

  @Test func theSourceReadThrowsForAMissingFolder() {
    #expect(throws: (any Error).self) {
      try FixtureFile.swiftSources(under: Self.missingFolder)
    }
  }
}
