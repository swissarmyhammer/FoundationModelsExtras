import FixtureSupport
import Foundation
import Testing

/// Guards the document that describes the marketplace: `README.md` holds
/// the section, and it names no marketplace grant, because there is no
/// per-marketplace permission.
///
/// The suite reads the document as text from the package root, as
/// `PackageLayoutTests` reads the manifest.
@Suite("Documentation")
struct DocumentationTests {
  /// The name of a type that no document may name: a marketplace layer
  /// always renders untrusted, and there is no per-marketplace permission.
  private static let grantsTypeName = "MarketplaceGrants"

  /// The documents, relative to the package root.
  private static let documentPaths = [MarketplaceTestSupport.readmePath]

  @Test func theReadmeHoldsTheMarketplaceSection() throws {
    let readme = try FixtureFile.text(MarketplaceTestSupport.readmePath).get()

    #expect(readme.contains(MarketplaceTestSupport.readmeMarketplaceHeading))
  }

  @Test(arguments: documentPaths)
  func noDocumentNamesAMarketplaceGrant(path: String) throws {
    let text = try FixtureFile.text(path).get()

    #expect(!text.contains(Self.grantsTypeName))
  }
}
