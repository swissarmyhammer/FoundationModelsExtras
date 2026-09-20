import FixtureSupport
import Foundation
import Testing

/// Guards the three documents of the marketplace pillar: `README.md` holds
/// the section, `plan.md` holds the pillar section with the decision date,
/// `CHANGELOG.md` holds the entry in the unreleased section, and
/// no document names a marketplace grant, because there is no
/// per-marketplace permission.
///
/// The suite reads the documents as text from the package root, as
/// `PackageLayoutTests` reads the manifest.
@Suite("Documentation")
struct DocumentationTests {
  /// The plan, relative to the package root.
  private static let planPath = "plan.md"

  /// The changelog, relative to the package root.
  private static let changelogPath = "CHANGELOG.md"

  /// The heading of the pillar section of the plan.
  private static let planHeading = "## 12. Pillar 6 — Marketplace (a fetched, cached, materialized layer root)"

  /// The date of the decision that the pillar section names.
  private static let decisionDate = "2026-09-19"

  /// The heading of the unreleased section of the changelog.
  private static let unreleasedHeading = "## Unreleased"

  /// The heading of the marketplace entry of the changelog.
  private static let changelogHeading = "### Added: the `Marketplace` product"

  /// The prefix of each entry heading of the changelog.
  private static let entryHeadingPrefix = "### "

  /// The name of a type that no document may name: a marketplace layer
  /// always renders untrusted, and there is no per-marketplace permission.
  private static let grantsTypeName = "MarketplaceGrants"

  /// The three documents, relative to the package root.
  private static let documentPaths = [MarketplaceTestSupport.readmePath, planPath, changelogPath]

  @Test func theReadmeHoldsTheMarketplaceSection() throws {
    let readme = try FixtureFile.text(MarketplaceTestSupport.readmePath).get()

    #expect(readme.contains(MarketplaceTestSupport.readmeMarketplaceHeading))
  }

  @Test func thePlanHoldsThePillarSectionWithTheDecisionDate() throws {
    let plan = try FixtureFile.text(Self.planPath).get()

    let section = try #require(plan.range(of: Self.planHeading))

    #expect(plan[section.lowerBound...].contains(Self.decisionDate))
  }

  @Test func theChangelogHoldsTheEntryUnderUnreleased() throws {
    let lines = try FixtureFile.text(Self.changelogPath).get().components(separatedBy: "\n")

    let unreleased = try #require(lines.firstIndex(of: Self.unreleasedHeading))
    let entries = lines[unreleased...].filter { $0.hasPrefix(Self.entryHeadingPrefix) }

    #expect(entries.contains(Self.changelogHeading))
  }

  @Test(arguments: documentPaths)
  func noDocumentNamesAMarketplaceGrant(path: String) throws {
    let text = try FixtureFile.text(path).get()

    #expect(!text.contains(Self.grantsTypeName))
  }
}
