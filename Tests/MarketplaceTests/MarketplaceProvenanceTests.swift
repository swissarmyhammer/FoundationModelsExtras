import Marketplace
import Testing

/// Proves the display text of ``MarketplaceProvenance``: the short commit
/// names the snapshot, the id alone is the text before the first install, and
/// the URL is never part of the text.
///
/// The suite imports `Marketplace` without `@testable`, thus it proves the
/// public surface that a consumer uses.
@Suite("Marketplace provenance")
struct MarketplaceProvenanceTests {
  /// The display id of the marketplace every case here builds.
  private static let marketplaceID = "swissarmyhammer-skills"

  /// The `url` field of the source. No display text may hold it.
  private static let url = "https://github.com/swissarmyhammer/skills.git"

  /// The commit of the snapshot of the marketplace.
  private static let commit = "abc1234def5678"

  /// The first characters of ``commit``: the text a row shows for the
  /// snapshot.
  private static let shortCommit = "abc1234"

  @Test func theShortCommitNamesTheSnapshot() {
    let provenance = MarketplaceProvenance(id: Self.marketplaceID, url: Self.url, sha: Self.commit)

    #expect(provenance.displayText == "\(Self.marketplaceID)@\(Self.shortCommit)")
  }

  @Test func theIdAloneIsTheTextBeforeTheFirstInstall() {
    let provenance = MarketplaceProvenance(id: Self.marketplaceID, url: Self.url)

    #expect(provenance.displayText == Self.marketplaceID)
  }

  @Test func theTextNeverHoldsTheURL() {
    let provenance = MarketplaceProvenance(id: Self.marketplaceID, url: Self.url, sha: Self.commit)

    #expect(!provenance.displayText.contains(Self.url))
  }
}
