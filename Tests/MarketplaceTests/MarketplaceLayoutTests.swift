import Marketplace
import Testing

/// Proves the values of ``MarketplaceLayout``: the host names the document
/// that marks an entry folder, and the other two values have a default.
///
/// The suite imports `Marketplace` without `@testable`, thus it proves the
/// public surface that a host uses.
@Suite("Marketplace layout")
struct MarketplaceLayoutTests {
  /// The document name of an agent marketplace, which is not the skills
  /// name.
  private static let agentDocumentName = "AGENT.md"

  @Test func theDocumentNameIsTheOneTheHostGives() {
    let layout = MarketplaceLayout(documentName: Self.agentDocumentName)

    #expect(layout.documentName == Self.agentDocumentName)
  }

  @Test func theExcludedFolderNamesAreTheGitAndNodeFoldersByDefault() {
    let layout = MarketplaceLayout(documentName: Self.agentDocumentName)

    #expect(layout.excludedDirectoryNames == [".git", "node_modules"])
  }

  @Test func thePartialsFolderNameIsTheDotfolderConventionByDefault() {
    let layout = MarketplaceLayout(documentName: Self.agentDocumentName)

    #expect(layout.partialsDirectoryName == "_partials")
  }

  @Test func theHostCanGiveEveryValue() {
    let layout = MarketplaceLayout(
      documentName: Self.agentDocumentName, excludedDirectoryNames: ["vendor"], partialsDirectoryName: "shared")

    #expect(layout.excludedDirectoryNames == ["vendor"])
    #expect(layout.partialsDirectoryName == "shared")
  }

  @Test func twoLayoutsWithTheSameValuesAreEqual() {
    #expect(
      MarketplaceLayout(documentName: Self.agentDocumentName)
        == MarketplaceLayout(documentName: Self.agentDocumentName))
  }
}
