import FixtureSupport
import Foundation
import Testing

/// Proves the shared readers of `FixtureSupport` that the manifest suites call:
/// the read of the manifest text, and the read of the `dependencies` list of a
/// target.
@Suite("Package manifest readers")
struct PackageManifestTests {
  /// A target name that the manifest does not declare.
  private static let missingTarget = "NoSuchTarget"

  /// The target of the sample manifest.
  private static let sampleTarget = "Sample"

  /// A target of the package that the sample target names by its name only.
  private static let sampleLocalTarget = "Local"

  /// A product that the sample target links.
  private static let sampleProduct = ManifestProduct(name: "SampleProduct", package: "sample-package")

  /// The name of the package of the sample manifest.
  private static let samplePackage = "SamplePackage"

  /// The path of the sources of the sample target.
  private static let samplePath = "Sources/Sample"

  /// A path that holds the start of a line comment and of a block comment.
  /// A read that removes a comment inside a string literal loses the text
  /// after the path.
  private static let samplePathWithCommentMarkers = "Sources//Sample/*"

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

  @Test func theReadRemovesABlockCommentWithACommaAndABracketInTheList() throws {
    let manifest = """
      .target(
          name: "\(Self.sampleTarget)",
          dependencies: [
              "\(Self.sampleLocalTarget)",
              /* A comment with a [bracket], and a comma. */
              \(Self.sampleProduct.dependencyText),
          ]
      ),
      """

    let entries = try PackageManifest.dependencies(ofTarget: Self.sampleTarget, in: manifest)

    #expect(entries == [.byName(Self.sampleLocalTarget), .linking(Self.sampleProduct)])
  }

  @Test func theReadKeepsACommentMarkerThatAStringLiteralHolds() throws {
    let manifest = """
      .target(
          name: "\(Self.sampleTarget)",
          path: "\(Self.samplePathWithCommentMarkers)",
          dependencies: [
              /* A comment after the path. */
              "\(Self.sampleLocalTarget)",
          ]
      ),
      """

    let entries = try PackageManifest.dependencies(ofTarget: Self.sampleTarget, in: manifest)

    #expect(entries == [.byName(Self.sampleLocalTarget)])
  }

  @Test func theReadFindsAnExecutableTarget() throws {
    let manifest = """
      .executableTarget(
          name: "\(Self.sampleTarget)",
          dependencies: ["\(Self.sampleLocalTarget)"],
          path: "\(Self.samplePath)"
      ),
      """

    let entries = try PackageManifest.dependencies(ofTarget: Self.sampleTarget, in: manifest)

    #expect(entries == [.byName(Self.sampleLocalTarget)])
  }

  @Test func theReadFindsATestTarget() throws {
    let manifest = """
      .testTarget(
          name: "\(Self.sampleTarget)",
          dependencies: [\(Self.sampleProduct.dependencyText)]
      ),
      """

    let entries = try PackageManifest.dependencies(ofTarget: Self.sampleTarget, in: manifest)

    #expect(entries == [.linking(Self.sampleProduct)])
  }

  @Test func theReadFindsTheListAfterAPathArgument() throws {
    let manifest = """
      .target(
          name: "\(Self.sampleTarget)",
          path: "\(Self.samplePath)",
          dependencies: ["\(Self.sampleLocalTarget)"]
      ),
      """

    let entries = try PackageManifest.dependencies(ofTarget: Self.sampleTarget, in: manifest)

    #expect(entries == [.byName(Self.sampleLocalTarget)])
  }

  @Test func theReadGivesNoEntryForATargetWithNoList() throws {
    let manifest = """
      .target(
          name: "\(Self.sampleTarget)",
          path: "\(Self.samplePath)"
      ),
      .target(
          name: "\(Self.sampleLocalTarget)",
          dependencies: [\(Self.sampleProduct.dependencyText)]
      ),
      """

    let entries = try PackageManifest.dependencies(ofTarget: Self.sampleTarget, in: manifest)

    #expect(entries.isEmpty)
  }

  @Test func theTargetListGivesTheNameOfEachTargetOfAnyKind() throws {
    let manifest = """
      let package = Package(
          name: "\(Self.samplePackage)",
          products: [
              .library(name: "\(Self.sampleTarget)", targets: ["\(Self.sampleTarget)"]),
          ],
          targets: [
              .target(name: "\(Self.sampleTarget)"),
              /* .target(name: "\(Self.missingTarget)"), */
              .binaryTarget(name: "\(Self.sampleLocalTarget)", path: "\(Self.samplePath)"),
          ]
      )
      """

    let names = try PackageManifest.targetNames(in: manifest)

    #expect(names == [Self.sampleTarget, Self.sampleLocalTarget])
  }

  @Test func theTargetListOfTheRealManifestHoldsTheCoreAndTheMarketplaceTargets() throws {
    let names = try PackageManifest.targetNames()

    #expect(names.contains(PackageManifest.coreTargetName))
    #expect(names.contains(PackageManifest.marketplaceTargetName))
  }

  @Test(arguments: try PackageManifest.targetNames())
  func theReadKnowsEachEntryOfEachTargetOfTheRealManifest(target: String) throws {
    let entries = try PackageManifest.dependencies(ofTarget: target)

    #expect(Self.unreadEntries(of: entries).isEmpty)
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

  /// Gives each entry of a form that the read does not know.
  ///
  /// - Parameter entries: The entries of the `dependencies` list of a target.
  /// - Returns: The text of each ``TargetDependency/unread(_:)`` entry.
  private static func unreadEntries(of entries: [TargetDependency]) -> [String] {
    entries.compactMap { entry in
      if case .unread(let text) = entry { text } else { nil }
    }
  }
}
