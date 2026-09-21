import FixtureSupport
import Foundation
import FoundationModelsExtras
import Marketplace
import MarketplaceFixtures
import Testing

/// The contract test of the `MarketplaceStore` example of `README.md`.
///
/// The example is real code in
/// ``theExampleReadsAMarketplaceSkillThroughTheStack()``, between two marker
/// comments. That test runs it over a repository that `GitFixtureRepository`
/// builds, and reads the fixture skill through the stack.
/// ``theReadmeBlockAndTheTestCopyAreTheSameText()`` reads this file and
/// `README.md` as text, and proves that the fenced block of the README
/// section and the code between the markers are the same text, line for
/// line. The comparison removes the leading and trailing whitespace of each
/// line, thus the README can indent the example in its own style, but it
/// cannot drift from the code that compiles and runs here.
///
/// The suite touches no network and no home directory: the example binds
/// its source to a `file://` repository, and its cache, its project folder
/// and its user folder to one temporary folder.
@Suite("README marketplace example")
struct ReadmeSnippetTests {
  /// The comment line that starts the example in this file.
  private static let exampleStart = "// README example: begin"

  /// The comment line that ends the example in this file.
  private static let exampleEnd = "// README example: end"

  /// The id of the fixture skill, which is its folder name. The README
  /// block names it as a literal, because the block is the README text.
  private static let skillID = "review"

  /// The body of the fixture skill. The README block names it as a
  /// literal, because the block is the README text.
  private static let skillBody = "Read the diff first."

  /// The path of the fixture skill in the repository: the `skills` folder
  /// convention of a repository with no catalog.
  private static let skillPath =
    "\(MarketplaceTestSupport.skillsFolderName)/\(skillID)/\(MarketplaceStoreFixture.skillsLayout.documentName)"

  @Test func theExampleReadsAMarketplaceSkillThroughTheStack() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: [
      Self.skillPath: .file(MarketplaceTestSupport.skillDocument(named: Self.skillID, body: Self.skillBody))
    ])
    let home = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: home) }
    let marketplaceURL = fixture.url
    let cacheDirectory = home.appendingPathComponent("cache", isDirectory: true)
    let workingDirectory = home.appendingPathComponent("project", isDirectory: true)
    let userDirectory = home.appendingPathComponent("config", isDirectory: true)

    // README example: begin
    let store = MarketplaceStore(
      sources: [MarketplaceSource(marketplaceURL)],
      layout: MarketplaceLayout(documentName: "SKILL.md"),
      cacheDirectory: cacheDirectory)
    await store.start()

    var stack = DotfolderStack(
      name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)
    stack.layers.insert(contentsOf: store.marketplaceLayers().map(\.layer), at: 0)

    let skill = stack.item(at: "review/SKILL.md")
    // skill?.layer.source == .marketplace
    // skill?.value.contains("Read the diff first.") == true
    // README example: end

    #expect(skill?.layer.source == .marketplace)
    #expect(skill?.value.contains(Self.skillBody) == true)
  }

  @Test func theReadmeBlockAndTheTestCopyAreTheSameText() throws {
    let readmeLines = try ReadmeExample.readmeLines(under: MarketplaceTestSupport.readmeMarketplaceHeading)
    let testLines = try ReadmeExample.lines(between: Self.exampleStart, and: Self.exampleEnd)

    #expect(!readmeLines.isEmpty, "the README block holds at least one line, or the check proves nothing")
    #expect(readmeLines == testLines)
  }
}
