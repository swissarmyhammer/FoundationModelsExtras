import FixtureSupport
import Foundation
import Testing

/// Guards the two documents that describe the marketplace: `README.md`
/// holds the section, `plan.md` holds the marketplace section with the
/// decision date, and no document names a marketplace grant, because there
/// is no per-marketplace permission.
///
/// The suite reads the documents as text from the package root, as
/// `PackageLayoutTests` reads the manifest.
@Suite("Documentation")
struct DocumentationTests {
  /// The design document `plan.md`, relative to the package root.
  private static let planPath = "plan.md"

  /// The heading of the marketplace section in `plan.md`.
  private static let planHeading = "## 12. Pillar 6 — Marketplace (a fetched, cached, materialized layer root)"

  /// The date of the decision that the marketplace section names.
  private static let decisionDate = "2026-09-19"

  /// The name of a type that no document may name: a marketplace layer
  /// always renders untrusted, and there is no per-marketplace permission.
  private static let grantsTypeName = "MarketplaceGrants"

  /// The two documents, relative to the package root.
  private static let documentPaths = [MarketplaceTestSupport.readmePath, planPath]

  @Test func theReadmeHoldsTheMarketplaceSection() throws {
    let readme = try FixtureFile.text(MarketplaceTestSupport.readmePath).get()

    #expect(readme.contains(MarketplaceTestSupport.readmeMarketplaceHeading))
  }

  @Test func thePlanHoldsThePillarSectionWithTheDecisionDate() throws {
    let plan = try FixtureFile.text(Self.planPath).get()

    let section = try #require(plan.range(of: Self.planHeading))

    #expect(plan[section.lowerBound...].contains(Self.decisionDate))
  }

  @Test(arguments: documentPaths)
  func noDocumentNamesAMarketplaceGrant(path: String) throws {
    let text = try FixtureFile.text(path).get()

    #expect(!text.contains(Self.grantsTypeName))
  }
}
