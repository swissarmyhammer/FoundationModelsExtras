import Marketplace
import Testing

/// Proves the display text of ``MarketplaceProvenance`` (marketplace.md
/// §9.1): the catalog version names the snapshot, the short commit stands in
/// when the catalog has no version, and the URL is never part of the text.
///
/// The suite imports `Marketplace` without `@testable`, thus it proves the
/// public surface that a consumer uses.
@Suite("Marketplace provenance")
struct MarketplaceProvenanceTests {
  /// The display id of the marketplace every case here builds.
  private static let marketplaceID = "swissarmyhammer-skills"

  /// The `url` field of the source. No display text may hold it.
  private static let url = "https://github.com/swissarmyhammer/skills.git"

  /// The catalog version of the marketplace, when the case gives it one.
  private static let catalogVersion = "1.2.0"

  /// The commit of the snapshot of the marketplace.
  private static let commit = "abc1234def5678"

  /// The first characters of ``commit``: the text a row shows when the
  /// catalog carries no version.
  private static let shortCommit = "abc1234"

  @Test func theCatalogVersionNamesTheSnapshot() {
    let provenance = MarketplaceProvenance(
      id: Self.marketplaceID, url: Self.url, sha: Self.commit, catalogVersion: Self.catalogVersion)

    #expect(provenance.displayText == "\(Self.marketplaceID)@\(Self.catalogVersion)")
  }

  @Test func theShortCommitNamesTheSnapshotWhenTheCatalogHasNoVersion() {
    let provenance = MarketplaceProvenance(id: Self.marketplaceID, url: Self.url, sha: Self.commit)

    #expect(provenance.displayText == "\(Self.marketplaceID)@\(Self.shortCommit)")
  }

  @Test func theIdAloneIsTheTextBeforeTheFirstInstall() {
    let provenance = MarketplaceProvenance(id: Self.marketplaceID, url: Self.url)

    #expect(provenance.displayText == Self.marketplaceID)
  }

  @Test func theTextNeverHoldsTheURL() {
    let provenance = MarketplaceProvenance(
      id: Self.marketplaceID, url: Self.url, sha: Self.commit, catalogVersion: Self.catalogVersion)

    #expect(!provenance.displayText.contains(Self.url))
  }
}
