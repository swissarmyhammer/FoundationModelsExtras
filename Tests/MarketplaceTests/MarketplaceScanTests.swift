import FixtureSupport
import Foundation
import Testing

@testable import Marketplace

/// Proves the folder scan that finds the skills and the agents of a
/// marketplace tree.
///
/// A marketplace is only a folder. The scan reads no catalog file. A folder
/// that holds the document of the layout (`SKILL.md` here) is a skill, and a
/// folder that holds `AGENT.md` is an agent.
///
/// The golden tests read the hand-written fixture trees in
/// `Tests/MarketplaceTests/Fixtures/marketplaces/` through a
/// ``LocalCatalogFileSource``, with a layout whose document is `SKILL.md`.
/// The edge tests write a small tree into a temporary folder. No test uses
/// the network or the `git` binary.
@Suite("Marketplace scan")
struct MarketplaceScanTests {
  /// The POSIX mode of an executable file.
  private static let executableMode = 0o755

  /// The document name of the skills layout that the fixtures use.
  private static let skillDocumentName = MarketplaceTestSupport.skillsLayout.documentName

  /// A document whose frontmatter is not YAML: the flow sequence never
  /// closes.
  private static let unparseableDocument = "---\nname: [\n---\n\nBody text.\n"

  /// The skills of the `anthropics/skills` fixture, in name order.
  private static let anthropicSkillNames = [
    "algorithmic-art", "brand-guidelines", "canvas-design", "doc-coauthoring", "docx", "frontend-design",
    "internal-comms", "mcp-builder", "pdf", "pptx", "skill-creator", "slack-gif-creator", "theme-factory",
    "web-artifacts-builder", "webapp-testing", "xlsx",
  ]

  /// The agents of the `swissarmyhammer-agents` fixture, in name order.
  private static let swissarmyhammerAgentNames = [
    "committer", "double-check", "explorer", "general-purpose", "implementer", "planner", "reviewer", "tester",
  ]

  /// A path that is seven folders deep, deeper than the old scan limit of
  /// three path components.
  private static let deepSkillFolder = "a/b/c/d/e/f/deep"

  /// Each selection of ``MarketplaceTestSupport/twoPluginAgentTree``, with
  /// the names of the agents that it gives.
  private static let agentSelections: [(selection: SkillSelection, agents: [String])] = [
    (.all, ["planner", "reviewer"]),
    (.skills(["alpha", "beta"]), []),
  ]

  // MARK: - The agent document

  @Test func theAgentDocumentIsNamedAgentMd() {
    #expect(MarketplaceLayer.agentDocumentName == "AGENT.md")
  }

  @Test func theAgentsFolderOfALayerIsNamedAgents() {
    #expect(MarketplaceLayer.agentsDirectoryName == "agents")
  }

  // MARK: - Golden trees

  @Test func theAnthropicTreeGivesEachSkillOfItsSkillsFolder() {
    let catalog = Self.resolvedCatalog(inFixture: "anthropics-skills")

    #expect(catalog.skills == Self.entries(named: Self.anthropicSkillNames, inFolder: "skills"))
    #expect(catalog.agents.isEmpty)
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theOfficialTreeGivesTheSkillsFiveFoldersDeep() {
    let catalog = Self.resolvedCatalog(inFixture: "claude-plugins-official")

    #expect(
      catalog.skills == [
        ResolvedEntry(name: "frontend-design", path: "plugins/frontend-design/skills/frontend-design"),
        ResolvedEntry(name: "skill-creator", path: "plugins/skill-creator/skills/skill-creator"),
      ])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func ourSkillsTreeGivesEachSkillOfItsSkillsFolder() {
    let catalog = Self.resolvedCatalog(inFixture: "swissarmyhammer-skills")

    #expect(catalog.skills == Self.entries(named: ["code-context", "commit", "tdd"], inFolder: "skills"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func ourAgentsTreeGivesEachAgentFolder() {
    let catalog = Self.resolvedCatalog(inFixture: "swissarmyhammer-agents")

    #expect(catalog.agents == Self.entries(named: Self.swissarmyhammerAgentNames, inFolder: "agents"))
    #expect(catalog.skills == Self.entries(named: ["code-context", "review"], inFolder: "skills"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theAgentLibraryTreeGivesTheSkillsAndTheAgentsOfEachPluginFolder() {
    let catalog = Self.resolvedCatalog(inFixture: "agent-library")

    #expect(catalog.skills == [ResolvedEntry(name: "review", path: "plugins/code-tools/skills/review")])
    #expect(
      catalog.agents == [
        ResolvedEntry(name: "security-reviewer", path: "plugins/code-tools/agents/security-reviewer"),
        ResolvedEntry(name: "doc-writer", path: "plugins/docs-tools/agents/doc-writer"),
      ])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aCatalogFileIsNotRead() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      ".claude-plugin/marketplace.json": #"{"name": "n", "plugins": [{"name": "p", "source": "./other"}]}"#,
      ".agents/plugins/marketplace.json": "{ not json",
      "skills/alpha/SKILL.md": Self.skillDocument(named: "alpha"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "alpha", path: "skills/alpha")])
    #expect(catalog.diagnostics.isEmpty)
  }

  // MARK: - The scan

  @Test func theScanGivesTheShallowerSkillsFirstThenPathOrder() {
    let catalog = Self.resolvedCatalog(inFixture: "repository-scan")

    #expect(
      catalog.skills == [
        ResolvedEntry(name: "gamma", path: "gamma"),
        ResolvedEntry(name: "alpha", path: "skills/alpha"),
        ResolvedEntry(name: "beta", path: "skills/beta"),
        ResolvedEntry(name: "delta", path: "nested/deep/delta"),
      ])
  }

  @Test func theScanHasNoDepthLimit() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "\(Self.deepSkillFolder)/SKILL.md": Self.skillDocument(named: "deep"),
      "a/b/c/d/e/f/g/agents/far/AGENT.md": MarketplaceTestSupport.agentDocument(named: "far"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "deep", path: Self.deepSkillFolder)])
    #expect(catalog.agents == [ResolvedEntry(name: "far", path: "a/b/c/d/e/f/g/agents/far")])
  }

  @Test func theScanDoesNotReadIntoASkillFolder() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "outer/SKILL.md": Self.skillDocument(named: "outer"),
      "outer/inner/SKILL.md": Self.skillDocument(named: "inner"),
      "outer/agents/helper/AGENT.md": MarketplaceTestSupport.agentDocument(named: "helper"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "outer", path: "outer")])
    #expect(catalog.agents.isEmpty)
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theScanDoesNotReadIntoAnAgentFolder() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "agents/lead/AGENT.md": MarketplaceTestSupport.agentDocument(named: "lead"),
      "agents/lead/tools/SKILL.md": Self.skillDocument(named: "tools"),
      "agents/lead/notes.md": "A resource of the agent.",
    ])

    #expect(catalog.agents == [ResolvedEntry(name: "lead", path: "agents/lead")])
    #expect(catalog.skills.isEmpty)
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aRootSkillDocumentGivesOneSkillNamedByItsFrontmatterAndStopsTheScan() {
    let catalog = Self.resolvedCatalog(inFixture: "single-skill-repository")

    #expect(catalog.skills == [ResolvedEntry(name: "solo", path: "")])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aRootAgentDocumentGivesOneAgentNamedByItsFrontmatter() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      MarketplaceLayer.agentDocumentName: MarketplaceTestSupport.agentDocument(named: "lead")
    ])

    #expect(catalog.agents == [ResolvedEntry(name: "lead", path: "")])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aRootSkillDocumentWithNoNameGivesOneWarningInPlaceOfASkill() {
    let catalog = Self.resolvedCatalog(inFixture: "nameless-root")

    #expect(catalog.skills.isEmpty)
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
  }

  @Test func theWarningForARootDocumentWithNoNameNamesTheDocument() {
    let catalog = Self.resolvedCatalog(inFixture: "nameless-root")

    #expect(
      catalog.diagnostics.map(\.message) == [
        "The root SKILL.md has no frontmatter name that is one folder name. The resolver skips it."
      ])
  }

  @Test func aRootDocumentWhoseFrontmatterDoesNotParseGivesOneWarningInPlaceOfASkill() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [Self.skillDocumentName: Self.unparseableDocument])

    #expect(catalog.skills.isEmpty)
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
  }

  @Test func aFolderDocumentWhoseFrontmatterDoesNotParseGivesTheFolderName() throws {
    let catalog = try Self.resolvedCatalog(ofTree: ["kept/SKILL.md": Self.unparseableDocument])

    #expect(catalog.skills == [ResolvedEntry(name: "kept", path: "kept")])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func anAgentIsNamedByItsFolderWithNoReadOfItsFrontmatter() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "agents/broken/AGENT.md": Self.unparseableDocument,
      "agents/plain/AGENT.md": "No frontmatter at all.",
      "agents/renamed/AGENT.md": MarketplaceTestSupport.agentDocument(named: "other-name"),
    ])

    #expect(catalog.agents == Self.entries(named: ["broken", "plain", "renamed"], inFolder: "agents"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theScanSkipsTheFoldersThatTheLayoutExcludes() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      ".git/hooks/SKILL.md": Self.skillDocument(named: "hooks"),
      "node_modules/package/SKILL.md": Self.skillDocument(named: "package"),
      "node_modules/agents/helper/AGENT.md": MarketplaceTestSupport.agentDocument(named: "helper"),
      "kept/SKILL.md": Self.skillDocument(named: "kept"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "kept", path: "kept")])
    #expect(catalog.agents.isEmpty)
  }

  @Test func aLayoutCanExcludeItsOwnFolderNames() throws {
    let root = try MarketplaceTestSupport.makeTempDirectory(withFiles: [
      "vendor/SKILL.md": Self.skillDocument(named: "vendor"),
      "kept/SKILL.md": Self.skillDocument(named: "kept"),
    ])
    let layout = MarketplaceLayout(documentName: Self.skillDocumentName, excludedDirectoryNames: ["vendor"])

    let catalog = CatalogResolver.resolve(from: LocalCatalogFileSource(root: root), selection: .all, layout: layout)

    #expect(catalog.skills == [ResolvedEntry(name: "kept", path: "kept")])
  }

  @Test func theDocumentOfTheLayoutMarksASkillFolder() throws {
    let root = try MarketplaceTestSupport.makeTempDirectory(withFiles: [
      "entries/planner/ENTRY.md": Self.skillDocument(named: "planner"),
      "skills/tdd/SKILL.md": Self.skillDocument(named: "tdd"),
    ])
    let layout = MarketplaceLayout(documentName: "ENTRY.md")

    let catalog = CatalogResolver.resolve(from: LocalCatalogFileSource(root: root), selection: .all, layout: layout)

    #expect(catalog.skills == [ResolvedEntry(name: "planner", path: "entries/planner")])
  }

  @Test(arguments: ["lower/skill.md", "lower/agent.md"])
  func aDocumentNameInAnotherCaseDoesNotMarkAnEntryFolder(path: String) throws {
    let catalog = try Self.resolvedCatalog(ofTree: [path: Self.skillDocument(named: "lower")])

    #expect(catalog.skills.isEmpty)
    #expect(catalog.agents.isEmpty)
  }

  // MARK: - A folder with two documents

  @Test func aFolderWithBothDocumentsGivesOneWarningAndNoEntry() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "both/SKILL.md": Self.skillDocument(named: "both"),
      "both/AGENT.md": MarketplaceTestSupport.agentDocument(named: "both"),
      "both/inner/SKILL.md": Self.skillDocument(named: "inner"),
      "kept/SKILL.md": Self.skillDocument(named: "kept"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "kept", path: "kept")])
    #expect(catalog.agents.isEmpty)
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "both").count == 1)
  }

  @Test func theWarningForAFolderWithBothDocumentsNamesTheTwoDocuments() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "both/SKILL.md": Self.skillDocument(named: "both"),
      "both/AGENT.md": MarketplaceTestSupport.agentDocument(named: "both"),
    ])

    #expect(
      catalog.diagnostics.map(\.message) == [
        #"The folder "both" holds SKILL.md and AGENT.md. A folder is one skill or one agent, thus the resolver skips it."#
      ])
  }

  // MARK: - Duplicate names

  @Test func theShallowerSkillWinsADuplicateNameWithOneWarning() {
    let catalog = Self.resolvedCatalog(inFixture: "duplicate-skills")

    #expect(
      catalog.skills == [
        ResolvedEntry(name: "alpha", path: "first/alpha"),
        ResolvedEntry(name: "shared", path: "first/shared"),
      ])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "second/skills/shared").count == 1)
  }

  @Test func theFirstSkillInPathOrderWinsADuplicateNameAtTheSameDepth() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "b/x/SKILL.md": Self.skillDocument(named: "x"),
      "a/x/SKILL.md": Self.skillDocument(named: "x"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "x", path: "a/x")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "b/x").count == 1)
  }

  @Test func eachSkillThatLosesADuplicateNameGivesOneWarning() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "x/SKILL.md": Self.skillDocument(named: "x"),
      "a/x/SKILL.md": Self.skillDocument(named: "x"),
      "b/x/SKILL.md": Self.skillDocument(named: "x"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "x", path: "x")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning, .warning])
  }

  @Test func theShallowerAgentWinsADuplicateNameWithOneWarning() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "plugins/p/agents/reviewer/AGENT.md": MarketplaceTestSupport.agentDocument(named: "reviewer"),
      "agents/reviewer/AGENT.md": MarketplaceTestSupport.agentDocument(named: "reviewer"),
    ])

    #expect(catalog.agents == [ResolvedEntry(name: "reviewer", path: "agents/reviewer")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "plugins/p/agents/reviewer").count == 1)
  }

  @Test func aSkillAndAnAgentWithTheSameNameAreNotDuplicates() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "skills/review/SKILL.md": Self.skillDocument(named: "review"),
      "agents/review/AGENT.md": MarketplaceTestSupport.agentDocument(named: "review"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "review", path: "skills/review")])
    #expect(catalog.agents == [ResolvedEntry(name: "review", path: "agents/review")])
    #expect(catalog.diagnostics.isEmpty)
  }

  // MARK: - The reserved skill name

  @Test func aSkillFolderNamedAgentsGivesOneWarningAndIsNotASkill() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "skills/agents/SKILL.md": Self.skillDocument(named: "agents"),
      "skills/alpha/SKILL.md": Self.skillDocument(named: "alpha"),
    ])

    #expect(catalog.skills == [ResolvedEntry(name: "alpha", path: "skills/alpha")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "skills/agents").count == 1)
  }

  // MARK: - The old agent file

  @Test func anOldAgentFileGivesOneWarningAndIsNotAnAgent() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "agents/planner.md": MarketplaceTestSupport.agentDocument(named: "planner"),
      "agents/reviewer/AGENT.md": MarketplaceTestSupport.agentDocument(named: "reviewer"),
    ])

    #expect(catalog.agents == [ResolvedEntry(name: "reviewer", path: "agents/reviewer")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
  }

  @Test func theWarningForAnOldAgentFileTellsWhereToMoveIt() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "plugins/p/agents/planner.md": MarketplaceTestSupport.agentDocument(named: "planner")
    ])

    #expect(
      catalog.diagnostics.map(\.message) == [
        #"The agent file "plugins/p/agents/planner.md" is in the old layout. Move it to "plugins/p/agents/planner/AGENT.md". The resolver skips it."#
      ])
  }

  @Test func onlyAnMdFileDirectlyInAnAgentsFolderIsAnOldAgentFile() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "agents/notes.txt": "Not an agent.",
      "agents/UPPER.MD": "Another case.",
      "docs/planner.md": "Not in an agents folder.",
    ])

    #expect(catalog.agents.isEmpty)
    #expect(catalog.diagnostics.isEmpty)
  }

  // MARK: - Selection

  @Test func aSkillsSelectionKeepsOnlyTheNamedSkillsInScanOrder() {
    let catalog = Self.resolvedCatalog(inFixture: "swissarmyhammer-skills", selection: .skills(["tdd", "commit"]))

    #expect(catalog.skills == Self.entries(named: ["commit", "tdd"], inFolder: "skills"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func anUnknownSelectedSkillGivesOneWarning() {
    let catalog = Self.resolvedCatalog(inFixture: "swissarmyhammer-skills", selection: .skills(["tdd", "missing"]))

    #expect(catalog.skills == Self.entries(named: ["tdd"], inFolder: "skills"))
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "missing").count == 1)
  }

  @Test func aSkillsSelectionFindsASkillAtAnyDepth() {
    let catalog = Self.resolvedCatalog(inFixture: "repository-scan", selection: .skills(["alpha", "delta"]))

    #expect(
      catalog.skills == [
        ResolvedEntry(name: "alpha", path: "skills/alpha"),
        ResolvedEntry(name: "delta", path: "nested/deep/delta"),
      ])
    #expect(catalog.diagnostics.count == 1)
    #expect(Self.diagnostics(in: catalog, naming: "skills/gamma").count == 1)
  }

  @Test func aSkillsSelectionGivesNoWarningAboutTheAgents() throws {
    let catalog = try Self.resolvedCatalog(
      ofTree: [
        "skills/alpha/SKILL.md": Self.skillDocument(named: "alpha"),
        "agents/planner.md": MarketplaceTestSupport.agentDocument(named: "planner"),
        "agents/reviewer/AGENT.md": MarketplaceTestSupport.agentDocument(named: "reviewer"),
        "plugins/p/agents/reviewer/AGENT.md": MarketplaceTestSupport.agentDocument(named: "reviewer"),
      ], selection: .skills(["alpha"]))

    #expect(catalog.skills == [ResolvedEntry(name: "alpha", path: "skills/alpha")])
    #expect(catalog.agents.isEmpty)
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test(arguments: agentSelections)
  func eachSelectionGivesTheAgentsOnlyForAll(selection: SkillSelection, agents: [String]) throws {
    let catalog = try Self.resolvedCatalog(ofTree: MarketplaceTestSupport.twoPluginAgentTree, selection: selection)

    #expect(catalog.agents.map(\.name) == agents)
    #expect(catalog.diagnostics.isEmpty)
  }

  // MARK: - Local file source

  @Test func aLocalSourceListsTheKindOfEachItemInNameOrder() throws {
    let root = try MarketplaceTestSupport.makeTempDirectory(
      withFiles: ["plain.txt": "plain", "run.sh": "echo hi", "folder/inner.txt": "inner"])
    try FileManager.default.setAttributes(
      [.posixPermissions: Self.executableMode], ofItemAtPath: root.appendingPathComponent("run.sh").path)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path, withDestinationPath: "plain.txt")

    let entries = try LocalCatalogFileSource(root: root).entries(inDirectory: "")

    #expect(
      entries == [
        CatalogTreeEntry(name: "folder", kind: .directory),
        CatalogTreeEntry(name: "link", kind: .symlink(target: "plain.txt")),
        CatalogTreeEntry(name: "plain.txt", kind: .file(isExecutable: false)),
        CatalogTreeEntry(name: "run.sh", kind: .file(isExecutable: true)),
      ])
  }

  @Test func aLocalSourceReadsTheBytesOfAFile() throws {
    let source = LocalCatalogFileSource(
      root: try MarketplaceTestSupport.makeTempDirectory(withFiles: ["folder/inner.txt": "inner"]))

    #expect(try source.contents(atPath: "folder/inner.txt") == Data("inner".utf8))
  }

  @Test(arguments: ["folder/missing.txt", "folder"])
  func aLocalSourceGivesNilForAPathThatIsNotAFile(path: String) throws {
    let source = LocalCatalogFileSource(
      root: try MarketplaceTestSupport.makeTempDirectory(withFiles: ["folder/inner.txt": "inner"]))

    #expect(try source.contents(atPath: path) == nil)
  }

  @Test func aLocalSourceGivesNoEntriesForAMissingFolder() throws {
    let source = LocalCatalogFileSource(root: try TemporaryDirectory.make())

    #expect(try source.entries(inDirectory: "missing").isEmpty)
  }

  @Test(arguments: ["../outside.txt", "/etc/hosts", "~/secret"])
  func aLocalSourceRefusesAPathOutsideItsRoot(path: String) throws {
    let source = LocalCatalogFileSource(root: try TemporaryDirectory.make())

    #expect(throws: CatalogFileSourceError.pathOutsideRoot(path)) {
      try source.contents(atPath: path)
    }
  }

  @Test func aLocalSourceRefusesASymlinkThatLeavesItsRoot() throws {
    let outside = try MarketplaceTestSupport.makeTempDirectory(withFiles: ["secret.txt": "secret"])
    let root = try TemporaryDirectory.make()
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"), withDestinationURL: outside.appendingPathComponent("secret.txt"))

    #expect(throws: CatalogFileSourceError.pathOutsideRoot("escape")) {
      try LocalCatalogFileSource(root: root).contents(atPath: "escape")
    }
  }

  // MARK: - Helpers

  /// Scans one fixture marketplace with the skills layout.
  ///
  /// - Parameters:
  ///   - name: The folder name of the fixture.
  ///   - selection: The host selection. The default is ``SkillSelection/all``.
  /// - Returns: The entries of the scan.
  private static func resolvedCatalog(inFixture name: String, selection: SkillSelection = .all) -> ResolvedCatalog {
    CatalogResolver.resolve(
      from: LocalCatalogFileSource(root: MarketplaceTestSupport.marketplaceFixture(named: name)),
      selection: selection, layout: MarketplaceTestSupport.skillsLayout)
  }

  /// Writes a tree into a new temporary folder and scans it with the skills
  /// layout.
  ///
  /// - Parameters:
  ///   - files: The text of each file, keyed by its path in the tree.
  ///   - selection: The host selection. The default is ``SkillSelection/all``.
  /// - Returns: The entries of the scan.
  /// - Throws: The error of a folder or file write.
  private static func resolvedCatalog(
    ofTree files: [String: String], selection: SkillSelection = .all
  ) throws -> ResolvedCatalog {
    CatalogResolver.resolve(
      from: LocalCatalogFileSource(root: try MarketplaceTestSupport.makeTempDirectory(withFiles: files)),
      selection: selection, layout: MarketplaceTestSupport.skillsLayout)
  }

  /// Makes the text of an entry document with a plain frontmatter.
  ///
  /// - Parameter name: The frontmatter `name`.
  /// - Returns: The document text.
  private static func skillDocument(named name: String) -> String {
    "---\nname: \(name)\ndescription: A fixture entry named \(name).\n---\n\nBody text for \(name).\n"
  }

  /// Makes the expected entries of one folder of entry folders.
  ///
  /// - Parameters:
  ///   - names: The entry names, in the expected order.
  ///   - folder: The folder that holds the entry folders.
  /// - Returns: One resolved entry for each name.
  private static func entries(named names: [String], inFolder folder: String) -> [ResolvedEntry] {
    names.map { ResolvedEntry(name: $0, path: "\(folder)/\($0)") }
  }

  /// Gives the diagnostics whose message quotes a name.
  ///
  /// - Parameters:
  ///   - catalog: The entries of a scan.
  ///   - name: The name, which the message puts in double quotes.
  /// - Returns: The diagnostics that quote the name.
  private static func diagnostics(in catalog: ResolvedCatalog, naming name: String) -> [MarketplaceDiagnostic] {
    catalog.diagnostics.filter { $0.message.contains("\"\(name)\"") }
  }
}
