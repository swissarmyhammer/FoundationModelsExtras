import FixtureSupport
import Foundation
import Testing

@testable import Marketplace

/// Proves the catalog reader and the entry resolver (marketplace.md §5.2 and
/// §6.4).
///
/// The golden tests read the hand-written fixture catalogs in
/// `Tests/MarketplaceTests/Fixtures/catalogs/` through a
/// ``LocalCatalogFileSource``, with a layout whose document is `SKILL.md`.
/// The edge tests write a small tree into a temporary folder. No test uses
/// the network or the `git` binary.
@Suite("Marketplace catalog")
struct MarketplaceCatalogTests {
  /// The path of the Claude catalog in a tree.
  private static let claudeCatalogPath = ".claude-plugin/marketplace.json"

  /// The POSIX mode of an executable file.
  private static let executableMode = 0o755

  /// The document name of the skills layout that the fixtures use.
  private static let skillDocumentName = MarketplaceTestSupport.skillsLayout.documentName

  /// A document whose frontmatter is not YAML: the flow sequence never
  /// closes.
  private static let unparseableDocument = "---\nname: [\n---\n\nBody text.\n"

  /// The remote plugins of the official catalog excerpt.
  private static let officialRemotePlugins = [
    "42crunch-api-security-testing", "agentforce-adlc", "airwallex-agentos", "amd-skills",
  ]

  /// The remote plugins of the `remote-plugins` fixture, one for each
  /// source kind.
  private static let remotePlugins = ["from-github", "from-git-subdir", "from-url", "from-npm"]

  /// The skills of the `document-skills` plugin of the `anthropics/skills`
  /// catalog.
  private static let documentSkillNames = ["xlsx", "docx", "pptx", "pdf"]

  /// The skills of the `example-skills` plugin of the `anthropics/skills`
  /// catalog.
  private static let exampleSkillNames = [
    "algorithmic-art", "brand-guidelines", "canvas-design", "doc-coauthoring", "frontend-design",
    "internal-comms", "mcp-builder", "skill-creator", "slack-gif-creator", "theme-factory",
    "web-artifacts-builder", "webapp-testing",
  ]

  /// The folder of a layer root, and of a plugin source, that holds the
  /// agent files.
  private static let agentsFolderName = "agents"

  /// A catalog with one plugin, `p`, at the root, whose `agents` list names
  /// `planner.md` and one entry more.
  ///
  /// - Parameter entry: The second entry of the `agents` list.
  /// - Returns: The JSON text of the catalog.
  private static func agentListCatalog(secondEntry entry: String) -> String {
    #"{"name": "n", "plugins": [{"name": "p", "source": "./", "agents": ["./agents/planner.md", "\#(entry)"]}]}"#
  }

  /// A tree whose `agents` folder holds one agent, a text file, a file
  /// with an upper-case extension, and a subfolder with one more `.md`
  /// file.
  private static let mixedAgentsFolder: [String: String] = [
    "agents/planner.md": MarketplaceTestSupport.agentDocument(named: "planner"),
    "agents/notes.txt": "Not an agent.",
    "agents/UPPER.MD": MarketplaceTestSupport.agentDocument(named: "upper"),
    "agents/nested/deep.md": MarketplaceTestSupport.agentDocument(named: "deep"),
  ]

  /// Each selection of ``MarketplaceTestSupport/twoPluginAgentTree``, with
  /// the file names of the agents that it gives.
  private static let catalogAgentSelections: [(selection: SkillSelection, agents: [String])] = [
    (.all, ["planner.md", "reviewer.md"]),
    (.plugins(["second"]), ["reviewer.md"]),
    (.plugins(["first", "second"]), ["planner.md", "reviewer.md"]),
    (.skills(["alpha", "beta"]), []),
  ]

  /// Each selection of a tree with no catalog, with the file names of the
  /// agents that it gives.
  private static let scanAgentSelections: [(selection: SkillSelection, agents: [String])] = [
    (.all, ["planner.md"]),
    (.skills(["alpha"]), []),
    (.plugins(["tools"]), []),
  ]

  // MARK: - Golden catalogs

  @Test func theAnthropicCatalogGivesEachSkillOfBothPlugins() {
    let catalog = Self.resolvedCatalog(inFixture: "anthropics-skills")

    #expect(catalog.name == "anthropic-agent-skills")
    #expect(catalog.version == "1.0.0")
    #expect(
      catalog.skills
        == Self.skills(named: Self.documentSkillNames, inFolder: "skills", plugin: "document-skills")
        + Self.skills(named: Self.exampleSkillNames, inFolder: "skills", plugin: "example-skills"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theOfficialCatalogExcerptGivesTheSkillsOfItsLocalPlugins() {
    let catalog = Self.resolvedCatalog(inFixture: "claude-plugins-official")

    #expect(catalog.name == "claude-plugins-official")
    #expect(catalog.version == nil)
    #expect(
      catalog.skills == [
        ResolvedSkill(
          name: "frontend-design", path: "plugins/frontend-design/skills/frontend-design",
          plugin: "frontend-design"),
        ResolvedSkill(
          name: "skill-creator", path: "plugins/skill-creator/skills/skill-creator",
          plugin: "skill-creator"),
      ])
  }

  @Test func theOfficialCatalogExcerptKeepsItsRenames() {
    let catalog = Self.resolvedCatalog(inFixture: "claude-plugins-official")

    #expect(catalog.renames == ["adlc": "agentforce-adlc", "airwallex": "airwallex-agentos"])
  }

  @Test func theOfficialCatalogExcerptGivesOneWarningForEachRemotePlugin() {
    let catalog = Self.resolvedCatalog(inFixture: "claude-plugins-official")

    #expect(catalog.diagnostics.count == Self.officialRemotePlugins.count)
    #expect(catalog.diagnostics.allSatisfy { $0.severity == .warning })
    #expect(catalog.diagnostics.allSatisfy { $0.marketplaceID == "claude-plugins-official" })
  }

  @Test(arguments: officialRemotePlugins)
  func eachRemotePluginOfTheOfficialExcerptHasOneDiagnostic(plugin: String) {
    let catalog = Self.resolvedCatalog(inFixture: "claude-plugins-official")

    #expect(Self.diagnostics(in: catalog, naming: plugin).count == 1)
  }

  @Test func ourCatalogGivesTheSkillsOfItsSkillArray() {
    let catalog = Self.resolvedCatalog(inFixture: "swissarmyhammer-skills")

    #expect(catalog.name == "swissarmyhammer-skills")
    #expect(catalog.version == "1.0.0")
    #expect(
      catalog.skills
        == Self.skills(named: ["code-context", "commit", "tdd"], inFolder: "skills", plugin: "swissarmyhammer"))
    #expect(catalog.diagnostics.isEmpty)
  }

  // MARK: - Catalog order

  @Test func theCodexCatalogIsReadWhenNoClaudeCatalogExists() {
    let catalog = Self.resolvedCatalog(inFixture: "codex-catalog")

    #expect(catalog.name == "codex-fixture")
    #expect(catalog.skills == Self.skills(named: ["format", "lint"], inFolder: "plugins/tools/skills", plugin: "tools"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theClaudeCatalogWinsOverTheCodexCatalog() {
    let catalog = Self.resolvedCatalog(inFixture: "claude-and-codex")

    #expect(catalog.name == "claude-first")
    #expect(catalog.skills == [ResolvedSkill(name: "from-claude", path: "skills/from-claude", plugin: "claude")])
  }

  @Test func anUndecodableCatalogGivesOneErrorInPlaceOfTheScan() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath: "{ not json",
      "skills/alpha/SKILL.md": Self.skillDocument(named: "alpha"),
    ])

    #expect(catalog.skills.isEmpty)
    #expect(catalog.diagnostics.map(\.severity) == [.error])
  }

  // MARK: - Plugins

  @Test func aCatalogWithRemotePluginsGivesOnlyTheSkillsOfItsLocalPlugin() {
    let catalog = Self.resolvedCatalog(inFixture: "remote-plugins")

    #expect(catalog.skills == [ResolvedSkill(name: "local-one", path: "skills/local-one", plugin: "local")])
    #expect(catalog.diagnostics.count == Self.remotePlugins.count)
  }

  @Test(arguments: remotePlugins)
  func aRemotePluginSourceIsSkippedWithOneWarning(plugin: String) {
    let catalog = Self.resolvedCatalog(inFixture: "remote-plugins")

    #expect(Self.diagnostics(in: catalog, naming: plugin).map(\.severity) == [.warning])
  }

  @Test func theLaterPluginWinsADuplicateSkillName() {
    let catalog = Self.resolvedCatalog(inFixture: "duplicate-skills")

    #expect(
      catalog.skills == [
        ResolvedSkill(name: "alpha", path: "first/alpha", plugin: "first"),
        ResolvedSkill(name: "shared", path: "second/skills/shared", plugin: "second"),
      ])
  }

  @Test func aDuplicateSkillNameGivesOneWarning() {
    let catalog = Self.resolvedCatalog(inFixture: "duplicate-skills")

    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "shared").count == 1)
  }

  @Test func aPluginSourceOutsideTheRepositoryGivesOneWarning() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath: #"{"name": "n", "plugins": [{"name": "escape", "source": "../outside"}]}"#
    ])

    #expect(catalog.skills.isEmpty)
    #expect(Self.diagnostics(in: catalog, naming: "escape").map(\.severity) == [.warning])
  }

  @Test func aListedSkillPathOutsideTheRepositoryGivesOneWarning() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath: #"{"name": "n", "plugins": [{"name": "p", "source": "./", "skills": ["../x"]}]}"#
    ])

    #expect(catalog.skills.isEmpty)
    #expect(Self.diagnostics(in: catalog, naming: "../x").map(\.severity) == [.warning])
  }

  @Test func aListedSkillFolderWithNoSkillFileGivesOneWarning() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath:
        #"{"name": "n", "plugins": [{"name": "p", "source": "./", "skills": ["./skills/empty", "./skills/real"]}]}"#,
      "skills/empty/README.md": "No skill here.",
      "skills/real/SKILL.md": Self.skillDocument(named: "real"),
    ])

    #expect(catalog.skills == [ResolvedSkill(name: "real", path: "skills/real", plugin: "p")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "skills/empty").count == 1)
  }

  @Test func theWarningForAListedFolderNamesTheDocumentOfTheLayout() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath: #"{"name": "n", "plugins": [{"name": "p", "source": "./", "skills": ["./empty"]}]}"#,
      "empty/README.md": "No skill here.",
    ])

    #expect(
      catalog.diagnostics.map(\.message) == [
        #"The plugin "p" lists the skill folder "empty", which has no SKILL.md file. The resolver skips it."#
      ])
  }

  // MARK: - Repository scan

  @Test func aFolderWithNoCatalogIsScannedToADepthOfThree() {
    let catalog = Self.resolvedCatalog(inFixture: "repository-scan")

    #expect(catalog.name == nil)
    #expect(catalog.version == nil)
    #expect(catalog.renames.isEmpty)
    #expect(
      catalog.skills == [
        ResolvedSkill(name: "gamma", path: "gamma", plugin: nil),
        ResolvedSkill(name: "alpha", path: "skills/alpha", plugin: nil),
        ResolvedSkill(name: "beta", path: "skills/beta", plugin: nil),
      ])
  }

  @Test func theScanFindsNoSkillDeeperThanThree() {
    let catalog = Self.resolvedCatalog(inFixture: "repository-scan")

    #expect(!catalog.skills.contains { $0.name == "delta" })
  }

  @Test func aShallowerSkillWinsOverADeeperSkillWithTheSameName() {
    let catalog = Self.resolvedCatalog(inFixture: "repository-scan")

    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "skills/gamma").count == 1)
  }

  @Test func aRootSkillFileGivesOneSkillNamedByItsFrontmatter() {
    let catalog = Self.resolvedCatalog(inFixture: "single-skill-repository")

    #expect(catalog.skills == [ResolvedSkill(name: "solo", path: "", plugin: nil)])
    #expect(Self.diagnostics(in: catalog, naming: "skills/solo").map(\.severity) == [.warning])
  }

  @Test func aRootSkillFileWithNoNameGivesOneWarningInPlaceOfASkill() {
    let catalog = Self.resolvedCatalog(inFixture: "nameless-root")

    #expect(catalog.skills.isEmpty)
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
  }

  @Test func theWarningForARootDocumentWithNoNameNamesTheDocumentOfTheLayout() {
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

    #expect(catalog.skills == [ResolvedSkill(name: "kept", path: "kept", plugin: nil)])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theScanSkipsTheFoldersThatTheLayoutExcludes() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      ".git/hooks/SKILL.md": Self.skillDocument(named: "hooks"),
      "node_modules/package/SKILL.md": Self.skillDocument(named: "package"),
      "kept/SKILL.md": Self.skillDocument(named: "kept"),
    ])

    #expect(catalog.skills == [ResolvedSkill(name: "kept", path: "kept", plugin: nil)])
  }

  @Test func aLayoutCanExcludeItsOwnFolderNames() throws {
    let root = try MarketplaceTestSupport.makeTempDirectory(withFiles: [
      "vendor/SKILL.md": Self.skillDocument(named: "vendor"),
      "kept/SKILL.md": Self.skillDocument(named: "kept"),
    ])
    let layout = MarketplaceLayout(documentName: Self.skillDocumentName, excludedDirectoryNames: ["vendor"])

    let catalog = CatalogResolver.resolve(from: LocalCatalogFileSource(root: root), selection: .all, layout: layout)

    #expect(catalog.skills == [ResolvedSkill(name: "kept", path: "kept", plugin: nil)])
  }

  @Test func theDocumentOfTheLayoutMarksAnEntryFolder() throws {
    let root = try MarketplaceTestSupport.makeTempDirectory(withFiles: [
      "agents/planner/AGENT.md": Self.skillDocument(named: "planner"),
      "skills/tdd/SKILL.md": Self.skillDocument(named: "tdd"),
    ])
    let layout = MarketplaceLayout(documentName: "AGENT.md")

    let catalog = CatalogResolver.resolve(from: LocalCatalogFileSource(root: root), selection: .all, layout: layout)

    #expect(catalog.skills == [ResolvedSkill(name: "planner", path: "agents/planner", plugin: nil)])
  }

  @Test func aDocumentNameInAnotherCaseDoesNotMarkAnEntryFolder() throws {
    let catalog = try Self.resolvedCatalog(ofTree: ["lower/skill.md": Self.skillDocument(named: "lower")])

    #expect(catalog.skills.isEmpty)
  }

  // MARK: - Selection

  @Test func aSkillsSelectionKeepsOnlyTheNamedSkillsInCatalogOrder() {
    let catalog = Self.resolvedCatalog(inFixture: "swissarmyhammer-skills", selection: .skills(["tdd", "commit"]))

    #expect(catalog.skills == Self.skills(named: ["commit", "tdd"], inFolder: "skills", plugin: "swissarmyhammer"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func anUnknownSelectedSkillGivesOneWarning() {
    let catalog = Self.resolvedCatalog(inFixture: "swissarmyhammer-skills", selection: .skills(["tdd", "missing"]))

    #expect(catalog.skills == Self.skills(named: ["tdd"], inFolder: "skills", plugin: "swissarmyhammer"))
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "missing").count == 1)
  }

  @Test func aPluginsSelectionKeepsOnlyTheSkillsOfThosePlugins() {
    let catalog = Self.resolvedCatalog(inFixture: "anthropics-skills", selection: .plugins(["document-skills"]))

    #expect(catalog.skills == Self.skills(named: Self.documentSkillNames, inFolder: "skills", plugin: "document-skills"))
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func anUnknownSelectedPluginGivesOneWarning() {
    let catalog = Self.resolvedCatalog(
      inFixture: "swissarmyhammer-skills", selection: .plugins(["swissarmyhammer", "other"]))

    #expect(
      catalog.skills
        == Self.skills(named: ["code-context", "commit", "tdd"], inFolder: "skills", plugin: "swissarmyhammer"))
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "other").count == 1)
  }

  @Test func aPluginsSelectionReadsNoUnselectedRemotePlugin() {
    let catalog = Self.resolvedCatalog(inFixture: "claude-plugins-official", selection: .plugins(["frontend-design"]))

    #expect(
      catalog.skills == [
        ResolvedSkill(
          name: "frontend-design", path: "plugins/frontend-design/skills/frontend-design",
          plugin: "frontend-design")
      ])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aSkillsSelectionOfAScanGivesOneWarningForASkillThatIsTooDeep() {
    let catalog = Self.resolvedCatalog(inFixture: "repository-scan", selection: .skills(["alpha", "delta"]))

    #expect(catalog.skills == [ResolvedSkill(name: "alpha", path: "skills/alpha", plugin: nil)])
    #expect(Self.diagnostics(in: catalog, naming: "delta").map(\.severity) == [.warning])
  }

  @Test func aPluginsSelectionOfAScanGivesOneWarningForEachName() {
    let catalog = Self.resolvedCatalog(inFixture: "repository-scan", selection: .plugins(["tools"]))

    #expect(catalog.skills.isEmpty)
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "tools").count == 1)
  }

  // MARK: - Renames

  @Test func aRenamedSelectedSkillMapsToTheNewNameWithOneAdvisory() {
    let catalog = Self.resolvedCatalog(inFixture: "renamed-skills", selection: .skills(["old-name"]))

    #expect(catalog.skills == [ResolvedSkill(name: "new-name", path: "skills/new-name", plugin: "main")])
    #expect(catalog.diagnostics.map(\.severity) == [.advisory])
  }

  @Test func aRemovedSelectedSkillGivesOneWarningInPlaceOfASkill() {
    let catalog = Self.resolvedCatalog(inFixture: "renamed-skills", selection: .skills(["retired"]))

    #expect(catalog.skills.isEmpty)
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
  }

  @Test func aRenamedSelectedPluginMapsToTheNewPlugin() {
    let catalog = Self.resolvedCatalog(inFixture: "renamed-skills", selection: .plugins(["old-plugin"]))

    #expect(catalog.skills == Self.skills(named: ["new-name", "steady"], inFolder: "skills", plugin: "main"))
    #expect(catalog.diagnostics.map(\.severity) == [.advisory])
  }

  @Test func theResolvedCatalogKeepsARemovedNameAsNil() {
    let catalog = Self.resolvedCatalog(inFixture: "renamed-skills")
    let expected: [String: String?] = ["old-name": "new-name", "retired": nil, "old-plugin": "main"]

    #expect(catalog.renames == expected)
  }

  // MARK: - Agents

  @Test func theAgentsFolderOfALayerIsNamedAgents() {
    #expect(MarketplaceLayer.agentsDirectoryName == Self.agentsFolderName)
  }

  @Test func aCatalogWithTwoPluginsGivesTheAgentsOfBothPlugins() throws {
    let catalog = try Self.resolvedCatalog(ofTree: MarketplaceTestSupport.twoPluginAgentTree)

    #expect(
      catalog.agents == [
        Self.agent(named: "planner", inFolder: "first", plugin: "first"),
        Self.agent(named: "reviewer", inFolder: "second", plugin: "second"),
      ])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func theLaterPluginWinsADuplicateAgentNameWithOneWarning() throws {
    var tree = MarketplaceTestSupport.twoPluginAgentTree
    tree["first/agents/reviewer.md"] = MarketplaceTestSupport.agentDocument(named: "reviewer")

    let catalog = try Self.resolvedCatalog(ofTree: tree)

    #expect(
      catalog.agents == [
        Self.agent(named: "planner", inFolder: "first", plugin: "first"),
        Self.agent(named: "reviewer", inFolder: "second", plugin: "second"),
      ])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "reviewer.md").count == 1)
  }

  @Test func anAgentsListGivesOnlyTheListedFiles() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath: #"{"name": "n", "plugins": [{"name": "p", "source": "./", "agents": ["./agents/planner.md"]}]}"#,
      "agents/planner.md": MarketplaceTestSupport.agentDocument(named: "planner"),
      "agents/reviewer.md": MarketplaceTestSupport.agentDocument(named: "reviewer"),
    ])

    #expect(catalog.agents == [Self.agent(named: "planner", inFolder: "", plugin: "p")])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test(arguments: ["./agents/notes.txt", "./agents/missing.md", "../outside.md", "./agents/nested", "./agents/UPPER.MD"])
  func anAgentsListEntryThatIsNotAnMdFileGivesOneWarning(entry: String) throws {
    var tree = Self.mixedAgentsFolder
    tree[Self.claudeCatalogPath] = Self.agentListCatalog(secondEntry: entry)

    let catalog = try Self.resolvedCatalog(ofTree: tree)

    #expect(catalog.agents == [Self.agent(named: "planner", inFolder: "", plugin: "p")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: entry).count == 1)
  }

  @Test func anAgentsValueOfOneTextIsAListOfOneEntry() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath: #"{"name": "n", "plugins": [{"name": "p", "source": "./", "agents": "./agents/planner.md"}]}"#,
      "agents/planner.md": MarketplaceTestSupport.agentDocument(named: "planner"),
      "agents/reviewer.md": MarketplaceTestSupport.agentDocument(named: "reviewer"),
    ])

    #expect(catalog.agents == [Self.agent(named: "planner", inFolder: "", plugin: "p")])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aPluginWithNoAgentsListGivesOnlyTheMdFilesDirectlyInItsAgentsFolder() throws {
    var tree = Self.mixedAgentsFolder
    tree[Self.claudeCatalogPath] = #"{"name": "n", "plugins": [{"name": "p", "source": "./"}]}"#

    let catalog = try Self.resolvedCatalog(ofTree: tree)

    #expect(catalog.agents == [Self.agent(named: "planner", inFolder: "", plugin: "p")])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aTreeWithNoCatalogGivesOnlyTheMdFilesDirectlyInItsAgentsFolder() throws {
    var tree = Self.mixedAgentsFolder
    tree["skills/alpha/SKILL.md"] = Self.skillDocument(named: "alpha")
    tree["agents/reviewer.md"] = MarketplaceTestSupport.agentDocument(named: "reviewer")

    let catalog = try Self.resolvedCatalog(ofTree: tree)

    #expect(
      catalog.agents == [
        Self.agent(named: "planner", inFolder: "", plugin: nil),
        Self.agent(named: "reviewer", inFolder: "", plugin: nil),
      ])
    #expect(catalog.skills == [ResolvedSkill(name: "alpha", path: "skills/alpha", plugin: nil)])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test(arguments: catalogAgentSelections)
  func eachSelectionOfACatalogGivesTheAgentsOfTheSelectedPlugins(selection: SkillSelection, agents: [String]) throws {
    let catalog = try Self.resolvedCatalog(ofTree: MarketplaceTestSupport.twoPluginAgentTree, selection: selection)

    #expect(catalog.agents.map(\.name) == agents)
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test(arguments: scanAgentSelections)
  func eachSelectionOfATreeWithNoCatalogGivesItsAgentsOnlyForAll(selection: SkillSelection, agents: [String]) throws {
    let catalog = try Self.resolvedCatalog(
      ofTree: [
        "skills/alpha/SKILL.md": Self.skillDocument(named: "alpha"),
        "agents/planner.md": MarketplaceTestSupport.agentDocument(named: "planner"),
      ], selection: selection)

    #expect(catalog.agents.map(\.name) == agents)
  }

  @Test func aRenamedSelectedPluginGivesTheAgentsOfTheNewPlugin() throws {
    let catalog = try Self.resolvedCatalog(
      ofTree: MarketplaceTestSupport.twoPluginAgentTree, selection: .plugins(["old"]))

    #expect(catalog.agents == [Self.agent(named: "reviewer", inFolder: "second", plugin: "second")])
    #expect(catalog.diagnostics.map(\.severity) == [.advisory])
  }

  @Test func anAgentFileIsTakenWithNoReadOfItsFrontmatter() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "agents/broken.md": Self.unparseableDocument,
      "agents/plain.md": "No frontmatter at all.",
    ])

    #expect(
      catalog.agents == [
        Self.agent(named: "broken", inFolder: "", plugin: nil),
        Self.agent(named: "plain", inFolder: "", plugin: nil),
      ])
    #expect(catalog.diagnostics.isEmpty)
  }

  @Test func aListedSkillFolderNamedAgentsGivesOneWarningAndIsNotASkill() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      Self.claudeCatalogPath:
        #"{"name": "n", "plugins": [{"name": "p", "source": "./", "skills": ["./skills/agents", "./skills/alpha"]}]}"#,
      "skills/agents/SKILL.md": Self.skillDocument(named: "agents"),
      "skills/alpha/SKILL.md": Self.skillDocument(named: "alpha"),
    ])

    #expect(catalog.skills == [ResolvedSkill(name: "alpha", path: "skills/alpha", plugin: "p")])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "skills/agents").count == 1)
  }

  @Test func aScannedSkillFolderNamedAgentsGivesOneWarningAndIsNotASkill() throws {
    let catalog = try Self.resolvedCatalog(ofTree: [
      "skills/agents/SKILL.md": Self.skillDocument(named: "agents"),
      "skills/alpha/SKILL.md": Self.skillDocument(named: "alpha"),
    ])

    #expect(catalog.skills == [ResolvedSkill(name: "alpha", path: "skills/alpha", plugin: nil)])
    #expect(catalog.diagnostics.map(\.severity) == [.warning])
    #expect(Self.diagnostics(in: catalog, naming: "skills/agents").count == 1)
  }

  // MARK: - Decoding

  @Test func aPluginSourceDecodesFromAString() throws {
    #expect(try Self.decodedPluginSource(fromJSON: #""./plugins/tools""#) == .relative("./plugins/tools"))
  }

  @Test func aLocalSourceObjectDecodesToARelativeSource() throws {
    let source = try Self.decodedPluginSource(fromJSON: #"{"source": "local", "path": "./plugins/tools"}"#)

    #expect(source == .relative("./plugins/tools"))
  }

  @Test func aRemoteSourceObjectKeepsItsKindAndLocation() throws {
    let source = try Self.decodedPluginSource(
      fromJSON: #"{"source": "git-subdir", "url": "https://example.com/a.git", "path": "p", "ref": "main", "sha": "abc"}"#
    )

    #expect(
      source
        == .remote(
          MarketplaceCatalog.RemotePluginSource(
            kind: "git-subdir", url: "https://example.com/a.git", repo: nil, path: "p", ref: "main",
            sha: "abc")))
  }

  @Test func aLocalSourceObjectWithNoPathDoesNotDecode() {
    #expect(throws: DecodingError.self) {
      try Self.decodedPluginSource(fromJSON: #"{"source": "local"}"#)
    }
  }

  @Test func aCatalogDecodesItsOwnerMetadataAndPluginFields() throws {
    let json = #"""
      {"name": "n", "owner": {"name": "o"}, "metadata": {"version": "2.0.0"},
       "plugins": [{"name": "p", "source": "./", "strict": false, "skills": ["./a"]}]}
      """#

    let catalog = try JSONDecoder().decode(MarketplaceCatalog.self, from: Data(json.utf8))

    #expect(catalog.owner?.name == "o")
    #expect(catalog.metadata?.version == "2.0.0")
    #expect(catalog.plugins.first?.strict == false)
    #expect(catalog.plugins.first?.skills == ["./a"])
    #expect(catalog.renames.isEmpty)
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

  /// Resolves one fixture catalog with the skills layout.
  ///
  /// - Parameters:
  ///   - name: The folder name of the fixture.
  ///   - selection: The host selection. The default is ``SkillSelection/all``.
  /// - Returns: The resolved catalog.
  private static func resolvedCatalog(inFixture name: String, selection: SkillSelection = .all) -> ResolvedCatalog {
    CatalogResolver.resolve(
      from: LocalCatalogFileSource(root: MarketplaceTestSupport.catalogFixture(named: name)), selection: selection,
      layout: MarketplaceTestSupport.skillsLayout)
  }

  /// Writes a tree into a new temporary folder and resolves it with the
  /// skills layout.
  ///
  /// - Parameters:
  ///   - files: The text of each file, keyed by its path in the tree.
  ///   - selection: The host selection. The default is ``SkillSelection/all``.
  /// - Returns: The resolved catalog.
  /// - Throws: The error of a folder or file write.
  private static func resolvedCatalog(
    ofTree files: [String: String], selection: SkillSelection = .all
  ) throws -> ResolvedCatalog {
    CatalogResolver.resolve(
      from: LocalCatalogFileSource(root: try MarketplaceTestSupport.makeTempDirectory(withFiles: files)),
      selection: selection, layout: MarketplaceTestSupport.skillsLayout)
  }

  /// Makes the expected agent of one `agents` folder.
  ///
  /// - Parameters:
  ///   - name: The agent name, with no `.md` extension.
  ///   - folder: The folder that holds the `agents` folder. The empty path
  ///     is the root.
  ///   - plugin: The plugin of the agent, or `nil` for a scan.
  /// - Returns: The resolved agent, named by its file name.
  private static func agent(named name: String, inFolder folder: String, plugin: String?) -> ResolvedAgent {
    let agentsFolder = folder.isEmpty ? Self.agentsFolderName : "\(folder)/\(Self.agentsFolderName)"
    return ResolvedAgent(name: "\(name).md", path: "\(agentsFolder)/\(name).md", plugin: plugin)
  }

  /// Makes the text of an entry document with a plain frontmatter.
  ///
  /// - Parameter name: The frontmatter `name`.
  /// - Returns: The document text.
  private static func skillDocument(named name: String) -> String {
    "---\nname: \(name)\ndescription: A fixture entry named \(name).\n---\n\nBody text for \(name).\n"
  }

  /// Makes the expected skills of one folder of skill folders.
  ///
  /// - Parameters:
  ///   - names: The skill names, in the expected order.
  ///   - folder: The folder that holds the skill folders.
  ///   - plugin: The plugin of the skills.
  /// - Returns: One resolved skill for each name.
  private static func skills(named names: [String], inFolder folder: String, plugin: String?) -> [ResolvedSkill] {
    names.map { ResolvedSkill(name: $0, path: "\(folder)/\($0)", plugin: plugin) }
  }

  /// Gives the diagnostics whose message quotes a name.
  ///
  /// - Parameters:
  ///   - catalog: The resolved catalog.
  ///   - name: The name, which the message puts in double quotes.
  /// - Returns: The diagnostics that quote the name.
  private static func diagnostics(in catalog: ResolvedCatalog, naming name: String) -> [MarketplaceDiagnostic] {
    catalog.diagnostics.filter { $0.message.contains("\"\(name)\"") }
  }

  /// Decodes the `source` value of one plugin entry.
  ///
  /// - Parameter json: The JSON text of the `source` value.
  /// - Returns: The decoded plugin source.
  /// - Throws: `DecodingError` when the value is not a plugin source.
  private static func decodedPluginSource(fromJSON json: String) throws -> MarketplaceCatalog.PluginSource {
    let plugin = #"{"name": "p", "source": \#(json)}"#
    return try JSONDecoder().decode(MarketplaceCatalog.Plugin.self, from: Data(plugin.utf8)).source
  }
}
