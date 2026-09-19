import Testing

import Marketplace

/// Proves the text of ``MarketplacePinError`` (marketplace.md §8.3): each
/// case names the id that the host gave, and no case names a URL.
@Suite("Marketplace pin error")
struct MarketplacePinErrorTests {
  /// The id that the host gave.
  private static let marketplaceID = "skills"

  /// The text that marks a URL in an error message.
  private static let schemeSeparator = "://"

  /// Each case of the error, with the id that the host gave.
  private static let cases: [MarketplacePinError] = [
    .unknownMarketplace(id: marketplaceID),
    .notAGitMarketplace(id: marketplaceID),
  ]

  @Test(arguments: cases)
  func eachCaseNamesTheMarketplaceID(error: MarketplacePinError) {
    #expect(String(describing: error).contains(#""\#(Self.marketplaceID)""#))
  }

  @Test(arguments: cases)
  func noCaseNamesAURL(error: MarketplacePinError) {
    #expect(!String(describing: error).contains(Self.schemeSeparator))
  }

  @Test func anUnknownMarketplaceSaysThatNoMarketplaceHasTheID() {
    let text = String(describing: MarketplacePinError.unknownMarketplace(id: Self.marketplaceID))

    #expect(text == #"No marketplace has the id "skills"."#)
  }

  @Test func aLocalFolderSaysThatItHasNoCommitToPin() {
    let text = String(describing: MarketplacePinError.notAGitMarketplace(id: Self.marketplaceID))

    #expect(text.contains("no commit to pin"))
  }
}
