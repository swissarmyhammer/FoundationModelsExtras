import FixtureSupport
import Foundation
import FoundationModelsExtras
import Marketplace
import Synchronization
import Testing

/// The example of how a marketplace combines with the local folders of a
/// host, rendered with Stencil.
///
/// One disk holds three folders:
///
/// ```
/// team-skills/skills/review/SKILL.md            marketplace only
/// team-skills/skills/deploy/SKILL.md            marketplace, hidden by project
/// team-skills/skills/_partials/rules.md         marketplace, hidden by user
/// team-skills/skills/_partials/footer.md        marketplace only
/// config/_partials/rules.md                     user
/// project/.myagent/deploy/SKILL.md              project
/// project/.myagent/local/SKILL.md               project, includes footer.md
/// ```
///
/// The marketplace is a `file://` folder, thus the example needs no git
/// fixture and no network. Each test names one rule of the combined stack.
@Suite("Example: a marketplace under local folders")
struct LayerPrecedenceExampleTests {
  /// The heading of the README section that holds the example.
  private static let readmeHeading = "### Example: a marketplace under local folders"

  /// The comment line that starts the example in this file.
  private static let exampleStart = "// README precedence example: begin"

  /// The comment line that ends the example in this file.
  private static let exampleEnd = "// README precedence example: end"

  // MARK: - The README example

  @Test func theExampleRendersEachSkillFromItsWinningLayer() throws {
    let disk = try ExampleDisk()
    defer { disk.remove() }
    let marketplaceURL = disk.marketplaceURL
    let workingDirectory = disk.workingDirectory
    let userDirectory = disk.userDirectory
    let cacheDirectory = disk.cacheDirectory

    // README precedence example: begin
    // Local folders: user (~/.config/myagent) < project (<cwd>/.myagent).
    var stack = DotfolderStack(
      name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)

    // The marketplace goes BELOW the local folders, so a local copy wins.
    let store = MarketplaceStore(
      sources: [MarketplaceSource(marketplaceURL)],
      layout: MarketplaceLayout(documentName: "SKILL.md"),
      cacheDirectory: cacheDirectory)
    stack.layers.insert(contentsOf: store.marketplaceLayers().map(\.layer), at: 0)

    // Stencil renders each file that a lookup gives.
    let skills = StenciledDotfolderStack(base: stack, variables: ["project": "acme"])
      .items(in: nil, named: "SKILL.md")

    // skills["review"]  from .marketplace: "Review acme. User rules. Marketplace footer."
    // skills["deploy"]  from .project:     "Project deploy of acme."
    // skills["local"]   nil: a local file cannot include a marketplace partial
    // README precedence example: end

    #expect(skills["review"]?.layer.source == .marketplace)
    #expect(skills["review"]?.value == "Review acme. User rules. Marketplace footer.")
    #expect(skills["deploy"]?.layer.source == .project)
    #expect(skills["deploy"]?.value == "Project deploy of acme.")
    #expect(skills["local"] == nil)
  }

  // MARK: - One test for each rule

  @Test func aSkillThatOnlyTheMarketplaceShipsComesFromTheMarketplace() throws {
    let disk = try ExampleDisk()
    defer { disk.remove() }

    let review = disk.stenciledStack().item(at: "review/SKILL.md")

    #expect(review?.layer.source == .marketplace)
  }

  @Test func aProjectCopyOfASkillWinsOverTheMarketplaceCopy() throws {
    let disk = try ExampleDisk()
    defer { disk.remove() }

    let deploy = disk.stenciledStack().item(at: "deploy/SKILL.md")

    #expect(deploy?.layer.source == .project)
    #expect(deploy?.value == "Project deploy of acme.")
  }

  @Test func aUserCopyOfAPartialWinsInsideAMarketplaceSkill() throws {
    let disk = try ExampleDisk()
    defer { disk.remove() }

    let review = disk.stenciledStack().content("review/SKILL.md")

    #expect(review?.contains("User rules.") == true)
    #expect(review?.contains("Marketplace rules.") == false)
  }

  @Test func aMarketplaceSkillIncludesAPartialThatOnlyTheMarketplaceShips() throws {
    let disk = try ExampleDisk()
    defer { disk.remove() }

    let review = disk.stenciledStack().content("review/SKILL.md")

    #expect(review?.contains("Marketplace footer.") == true)
  }

  @Test func aLocalSkillCannotIncludeAPartialThatOnlyTheMarketplaceShips() throws {
    let disk = try ExampleDisk()
    defer { disk.remove() }
    let failures = Mutex<[DotfolderStack.Diagnostic]>([])

    let local = disk.stenciledStack { failure in failures.withLock { $0.append(failure) } }
      .item(at: "local/SKILL.md")

    #expect(local == nil)
    #expect(failures.withLock { $0.map(\.layer.source) } == [.project])
  }

  // MARK: - The README copy

  @Test func theReadmeBlockAndTheTestCopyAreTheSameText() throws {
    let readmeLines = try ReadmeExample.readmeLines(under: Self.readmeHeading)
    let testLines = try ReadmeExample.lines(between: Self.exampleStart, and: Self.exampleEnd)

    #expect(!readmeLines.isEmpty, "the README block holds at least one line, or the check proves nothing")
    #expect(readmeLines == testLines)
  }
}

// MARK: - The disk of the example

/// The three folders of the example, in one temporary folder.
private struct ExampleDisk {
  /// The temporary folder that holds every other folder.
  let root: URL

  /// Writes the files of the example.
  ///
  /// - Throws: The error of a folder or a file write.
  init() throws {
    root = try TemporaryDirectory.make()
    try write("team-skills/skills/review/SKILL.md", #"Review {{ project }}. {% include "rules.md" %} {% include "footer.md" %}"#)
    try write("team-skills/skills/deploy/SKILL.md", "Marketplace deploy of {{ project }}.")
    try write("team-skills/skills/_partials/rules.md", "Marketplace rules.")
    try write("team-skills/skills/_partials/footer.md", "Marketplace footer.")
    try write("config/_partials/rules.md", "User rules.")
    try write("project/.myagent/deploy/SKILL.md", "Project deploy of {{ project }}.")
    try write("project/.myagent/local/SKILL.md", #"Local skill. {% include "footer.md" %}"#)
  }

  /// The `file://` URL of the marketplace folder.
  var marketplaceURL: String { root.appendingPathComponent("team-skills", isDirectory: true).absoluteString }

  /// The project folder. Its project layer is `.myagent` in it.
  var workingDirectory: URL { root.appendingPathComponent("project", isDirectory: true) }

  /// The user layer.
  var userDirectory: URL { root.appendingPathComponent("config", isDirectory: true) }

  /// The cache of the store. A folder source writes nothing into it.
  var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }

  /// The combined stack of the example, rendered with `project = acme`.
  ///
  /// - Parameter onDiagnostic: The hook that receives each render failure.
  /// - Returns: The stenciled stack, `marketplace < user < project`.
  func stenciledStack(
    onDiagnostic: @escaping StenciledDotfolderStack.DiagnosticHandler = { _ in }
  ) -> StenciledDotfolderStack {
    var stack = DotfolderStack(
      name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)
    let store = MarketplaceStore(
      sources: [MarketplaceSource(marketplaceURL)],
      layout: MarketplaceLayout(documentName: "SKILL.md"),
      cacheDirectory: cacheDirectory)
    stack.layers.insert(contentsOf: store.marketplaceLayers().map(\.layer), at: 0)
    return StenciledDotfolderStack(
      base: stack, variables: ["project": "acme"], onDiagnostic: onDiagnostic)
  }

  /// Removes the temporary folder.
  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  /// Writes `text` to `relativePath` under ``root``.
  ///
  /// - Parameters:
  ///   - relativePath: The path of the file under ``root``.
  ///   - text: The text of the file.
  /// - Throws: The error of the folder or of the file write.
  private func write(_ relativePath: String, _ text: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }
}
