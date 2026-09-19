import FixtureSupport
import Foundation
import FoundationModelsExtras
import Marketplace
import Testing

/// Proves how `MarketplaceConfig` reads `marketplaces.yaml` from the user and
/// project layers, merges the two lists, and writes a file back
/// (marketplace.md §6.3).
///
/// Each test makes its own temporary stack, so no test reads the real home
/// folder or the files of another test.
@Suite("Marketplace config")
struct MarketplaceConfigTests {
  // MARK: - Load

  @Test func aMissingFileGivesAnEmptyList() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: true)

    #expect(config.marketplaces.isEmpty)
  }

  @Test func aUserFileGivesItsEntriesInFileOrder() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: git@github.com:swissarmyhammer/skills.git
          - url: github:acme/team-skills
            ref: stable
            autoUpdate: false
        """,
      to: fixture.userFile)

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: true)

    #expect(
      config.marketplaces == [
        MarketplaceSource("git@github.com:swissarmyhammer/skills.git"),
        MarketplaceSource("github:acme/team-skills", ref: "stable", autoUpdate: false),
      ])
  }

  @Test func theProjectListComesAfterTheUserList() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/one
          - url: github:acme/two
        """,
      to: fixture.userFile)
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/three
        """,
      to: fixture.projectFile)

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: true)

    #expect(
      config.marketplaces == [
        MarketplaceSource("github:acme/one"),
        MarketplaceSource("github:acme/two"),
        MarketplaceSource("github:acme/three"),
      ])
  }

  @Test func aProjectEntryWithTheSameAliasReplacesTheUserEntryCompletely() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/skills
            alias: team
            ref: stable
            autoUpdate: false
          - url: github:acme/other
        """,
      to: fixture.userFile)
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/forked-skills
            alias: team
        """,
      to: fixture.projectFile)

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: true)

    #expect(
      config.marketplaces == [
        MarketplaceSource("github:acme/other"),
        MarketplaceSource("github:acme/forked-skills", alias: "team"),
      ])
  }

  @Test func aProjectEntryWithTheSameNormalizedURLReplacesTheUserEntryCompletely() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/skills
            ref: stable
            autoUpdate: false
          - url: github:acme/other
        """,
      to: fixture.userFile)
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: https://GitHub.com/acme/skills.git/
        """,
      to: fixture.projectFile)

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: true)

    #expect(
      config.marketplaces == [
        MarketplaceSource("github:acme/other"),
        MarketplaceSource("https://GitHub.com/acme/skills.git/"),
      ])
  }

  @Test func anAliasAndAURLAreNeverTheSameMergeKey() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/skills
        """,
      to: fixture.userFile)
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/other
            alias: https://github.com/acme/skills.git
        """,
      to: fixture.projectFile)

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: true)

    #expect(
      config.marketplaces == [
        MarketplaceSource("github:acme/skills"),
        MarketplaceSource("github:acme/other", alias: "https://github.com/acme/skills.git"),
      ])
  }

  @Test func anEntryThatStillCarriesAGrantsKeyLoadsWithTheSameURL() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/skills
            grants:
              shellInjection: true
              scripts: true
        """,
      to: fixture.userFile)

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: true)

    #expect(config.marketplaces == [MarketplaceSource("github:acme/skills")])
  }

  @Test func aProjectFileHasNoEffectWhenTheProjectIsNotIncluded() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:acme/skills
            alias: team
        """,
      to: fixture.userFile)
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - url: github:evil/skills
            alias: team
          - url: github:evil/more
        """,
      to: fixture.projectFile)

    let config = try MarketplaceConfig.load(from: fixture.stack, includeProject: false)

    #expect(config.marketplaces == [MarketplaceSource("github:acme/skills", alias: "team")])
  }

  // MARK: - Save

  @Test func aSavedConfigLoadsAsTheSameList() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    let config = MarketplaceConfig(marketplaces: [
      MarketplaceSource("git@github.com:swissarmyhammer/skills.git"),
      MarketplaceSource(
        "github:acme/team-skills",
        ref: "stable",
        sha: "0123456789abcdef0123456789abcdef01234567",
        path: "catalog",
        alias: "team",
        select: .plugins(["sah"]),
        autoUpdate: false),
      MarketplaceSource("file:///Users/me/skills", select: .skills(["plan", "review"])),
    ])

    try config.save(to: fixture.userFile)

    #expect(try MarketplaceConfig.load(from: fixture.stack, includeProject: false) == config)
  }

  @Test func saveMakesTheMissingFolderOfTheFile() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    let config = MarketplaceConfig(marketplaces: [MarketplaceSource("github:acme/skills")])

    try config.save(to: fixture.projectFile)

    #expect(try MarketplaceConfig.load(from: fixture.stack, includeProject: true) == config)
  }

  // MARK: - Errors

  @Test func aFileThatIsNotValidYAMLThrowsAnErrorThatNamesTheFile() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(text: "marketplaces: [", to: fixture.userFile)

    let error = #expect(throws: MarketplaceConfigError.self) {
      try MarketplaceConfig.load(from: fixture.stack, includeProject: false)
    }

    #expect(error?.file == fixture.userFile)
    #expect(error?.description.contains(fixture.userFile.path) == true)
  }

  @Test func aFileWithAnEntryThatHasNoURLThrowsAnErrorThatNamesTheFile() throws {
    let fixture = try ConfigFixture()
    defer { fixture.remove() }
    try MarketplaceTestSupport.writeFile(
      text: """
        marketplaces:
          - alias: team
        """,
      to: fixture.projectFile)

    let error = #expect(throws: MarketplaceConfigError.self) {
      try MarketplaceConfig.load(from: fixture.stack, includeProject: true)
    }

    #expect(error?.file == fixture.projectFile)
    #expect(error?.description.contains(fixture.projectFile.path) == true)
  }
}

/// A temporary dotfolder stack with a user layer and a project layer, and no
/// file in either layer at the start.
private struct ConfigFixture {
  /// The dotfolder name of the test stack.
  private static let stackName = "skills"

  /// The temporary folder that holds both layers.
  let root: URL

  /// The stack over `root`. Its environment is empty, so no real
  /// `XDG_CONFIG_HOME` or defaults override moves a layer.
  let stack: DotfolderStack

  /// The `marketplaces.yaml` path in the user layer.
  let userFile: URL

  /// The `marketplaces.yaml` path in the project layer.
  let projectFile: URL

  /// Makes the temporary folder and the stack. The layer folders do not
  /// exist yet.
  ///
  /// - Throws: The error of `TemporaryDirectory.make()`, or of `#require`
  ///   when the stack has no user layer or no project layer.
  init() throws {
    root = try TemporaryDirectory.make()
    stack = DotfolderStack(
      name: Self.stackName,
      workingDirectory: root,
      userDirectory: root.appendingPathComponent("user", isDirectory: true),
      environment: [:])
    userFile = try #require(stack.layers.first { $0.source == .user })
      .root.appendingPathComponent(MarketplaceConfig.fileName)
    projectFile = try #require(stack.layers.first { $0.source == .project })
      .root.appendingPathComponent(MarketplaceConfig.fileName)
  }

  /// Removes the temporary folder and everything in it.
  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
