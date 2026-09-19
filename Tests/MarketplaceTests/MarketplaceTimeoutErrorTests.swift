import Testing

@testable import Marketplace

/// Proves the text of ``MarketplaceTimeoutError`` (marketplace.md §8.2): it
/// names the fetch timeout of the policy, and it names no URL.
@Suite("Marketplace timeout error")
struct MarketplaceTimeoutErrorTests {
  /// The text that marks a URL in an error message.
  private static let schemeSeparator = "://"

  @Test func theTextNamesTheFetchTimeoutOfThePolicy() {
    let text = String(describing: MarketplaceTimeoutError())

    #expect(text.contains("fetch timeout"))
    #expect(text.contains("policy"))
  }

  @Test func theTextNamesNoURL() {
    let text = String(describing: MarketplaceTimeoutError())

    #expect(!text.contains(Self.schemeSeparator))
  }

  @Test func twoTimeoutErrorsAreEqual() {
    #expect(MarketplaceTimeoutError() == MarketplaceTimeoutError())
  }
}
