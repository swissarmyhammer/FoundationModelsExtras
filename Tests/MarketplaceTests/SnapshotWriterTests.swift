import FixtureSupport
import Foundation
import Testing

@testable import Marketplace

/// Proves the snapshot writer, which builds a snapshot after the fetch: one
/// flat folder that holds `<entry>/` for each selected skill,
/// `agents/<name>/` for each agent, and the partials folder that the layout
/// names, the execute bit, the validation rules, and the diagnostics.
///
/// Each test writes into its own temporary folder, so no test reads the files
/// of another test. The happy path scans a fixture marketplace through
/// ``LocalCatalogFileSource``. The rejection tests read an in-memory source,
/// because a folder on the disk cannot hold a submodule entry and a test
/// should not need a name that the file system itself refuses.
@Suite("Marketplace snapshot writer")
struct SnapshotWriterTests {
  // MARK: - Fixture

  /// The fixture marketplace of the happy path: three skills and one
  /// partial.
  private static let fixtureName = "swissarmyhammer-skills"

  /// The entry folders of a full snapshot of ``fixtureName``, in name
  /// order, after the partials folder.
  private static let fixtureEntryNames = ["code-context", "commit", "tdd"]

  /// The number of files that a full snapshot of ``fixtureName`` holds:
  /// three `SKILL.md` files, one extra file of the `tdd` skill, and one
  /// partial.
  private static let fixtureFileCount = 5

  /// The tree path of the first file that a full snapshot of
  /// ``fixtureName`` copies. The scan gives `code-context` first.
  private static let fixtureFirstFilePath = "skills/code-context/SKILL.md"

  /// The tree path of the second file that a full snapshot of
  /// ``fixtureName`` copies. A limit of one file permits the first file,
  /// so this file is the one that reaches the limit.
  private static let fixtureSecondFilePath = "skills/commit/SKILL.md"

  /// Limits that no test tree reaches.
  private static let generousLimits = SnapshotLimits(maxBytes: 1 << 20, maxFiles: 100)

  /// A limit of one, to prove that the writer counts.
  private static let limitOfOne = 1

  /// The permissions that an executable file of a snapshot has.
  private static let executablePermissions = 0o755

  /// The layout of the tests: `SKILL.md` marks a skill, and the partials
  /// folder has the default name.
  private static let layout = MarketplaceTestSupport.skillsLayout

  /// The partials folder name of ``layout``.
  private static let partialsName = layout.partialsDirectoryName

  /// The name of the agent document.
  private static let agentDocumentName = MarketplaceLayer.agentDocumentName

  /// A temporary folder, and the snapshot folder that the writer makes
  /// inside it.
  private struct Destination {
    /// The temporary folder that holds the snapshot folder.
    let parent: URL

    /// The folder that the writer makes. It does not exist yet.
    var folder: URL {
      parent.appendingPathComponent("snapshot", isDirectory: true)
    }

    /// Whether the writer left the snapshot folder on the disk.
    var folderExists: Bool {
      FileManager.default.fileExists(atPath: folder.path)
    }

    /// Makes a new temporary folder.
    ///
    /// - Throws: The error of the folder.
    init() throws {
      parent = try TemporaryDirectory.make()
    }

    /// Deletes the temporary folder.
    func remove() {
      try? FileManager.default.removeItem(at: parent)
    }

    /// The names of the items of one folder of the snapshot, in order.
    ///
    /// - Parameter relativePath: The folder, relative to ``folder``. The
    ///   empty path is ``folder`` itself.
    /// - Returns: The names, sorted.
    /// - Throws: The error of the folder read.
    func names(inFolder relativePath: String = "") throws -> [String] {
      let url = relativePath.isEmpty ? folder : folder.appendingPathComponent(relativePath)
      return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    /// The text of one file of the snapshot.
    ///
    /// - Parameter relativePath: The file, relative to ``folder``.
    /// - Returns: The text of the file.
    /// - Throws: The error of the file read.
    func text(ofFile relativePath: String) throws -> String {
      try String(contentsOf: folder.appendingPathComponent(relativePath), encoding: .utf8)
    }
  }

  /// A ``CatalogFileSource`` that holds one tree in memory.
  ///
  /// A folder on the disk cannot hold a submodule entry, and the file
  /// system refuses a name such as `..`, so the rejection tests need a
  /// source that gives the writer exactly the entries of the test.
  private struct MemoryCatalogFileSource: CatalogFileSource {
    /// The text of each file, keyed by its tree path.
    var files: [String: String] = [:]

    /// The items of each folder, keyed by its tree path.
    var listings: [String: [CatalogTreeEntry]] = [:]

    /// Reads the bytes of one file.
    ///
    /// - Parameter path: The tree path of the file.
    /// - Returns: The bytes, or `nil` when no file is at the path.
    func contents(atPath path: String) throws -> Data? {
      files[path].map { Data($0.utf8) }
    }

    /// Lists the items of one folder.
    ///
    /// - Parameter path: The tree path of the folder.
    /// - Returns: The items, or an empty list when no folder is at the
    ///   path.
    func entries(inDirectory path: String) throws -> [CatalogTreeEntry] {
      listings[path] ?? []
    }
  }

  /// The kind of the one entry of an in-memory tree.
  ///
  /// A parameterized test takes it as an argument, thus it is `internal`
  /// and not `private`.
  enum MemoryEntryKind {
    /// The folder is a skill.
    case skill

    /// The folder is an agent.
    case agent
  }

  /// Makes a source and the scan result of one entry folder that holds the
  /// given items, for the rejection tests.
  ///
  /// - Parameters:
  ///   - entries: The items of the entry folder.
  ///   - files: The text of each file of the entry folder, keyed by its
  ///     name. The default is no file.
  ///   - kind: Whether the folder is a skill or an agent. The default is a
  ///     skill.
  /// - Returns: The source and the scan result that names the one entry.
  private static func oneEntry(
    holding entries: [CatalogTreeEntry], files: [String: String] = [:], kind: MemoryEntryKind = .skill
  ) -> (source: MemoryCatalogFileSource, catalog: ResolvedCatalog) {
    let folder = "tool"
    let source = MemoryCatalogFileSource(
      files: Dictionary(uniqueKeysWithValues: files.map { ("\(folder)/\($0.key)", $0.value) }),
      listings: [folder: entries])
    let entry = ResolvedEntry(name: folder, path: folder)
    let catalog =
      switch kind {
      case .skill: ResolvedCatalog(skills: [entry], diagnostics: [])
      case .agent: ResolvedCatalog(skills: [], agents: [entry], diagnostics: [])
      }
    return (source, catalog)
  }

  /// Writes a snapshot of one in-memory tree with the test layout and
  /// generous limits.
  ///
  /// - Parameters:
  ///   - tree: The source and the scan result of the tree.
  ///   - destination: The folder that the writer makes.
  /// - Returns: The report of the write.
  /// - Throws: The error of the write.
  private static func write(
    _ tree: (source: MemoryCatalogFileSource, catalog: ResolvedCatalog), to destination: Destination
  ) throws -> SnapshotReport {
    try SnapshotWriter.write(
      catalog: tree.catalog, from: tree.source, to: destination.folder, layout: layout, limits: generousLimits)
  }

  /// Scans a folder on the disk and writes its snapshot.
  ///
  /// - Parameters:
  ///   - root: The root folder of the tree.
  ///   - selection: The skills that the host takes.
  ///   - layout: The layout of the tree.
  ///   - limits: The policy limits of the write.
  ///   - destination: The folder that the writer makes.
  /// - Returns: The report of the write.
  /// - Throws: The error of the write.
  private static func writeSnapshot(
    ofFolder root: URL, selection: SkillSelection, layout: MarketplaceLayout, limits: SnapshotLimits,
    to destination: Destination
  ) throws -> SnapshotReport {
    let source = LocalCatalogFileSource(root: root)
    let catalog = CatalogResolver.resolve(from: source, selection: selection, layout: layout)
    return try SnapshotWriter.write(
      catalog: catalog, from: source, to: destination.folder, layout: layout, limits: limits)
  }

  /// Writes a snapshot of one fixture marketplace with the test layout.
  ///
  /// - Parameters:
  ///   - name: The folder name of the fixture.
  ///   - selection: The skills that the host takes.
  ///   - destination: The folder that the writer makes.
  ///   - limits: The policy limits of the write.
  /// - Returns: The report of the write.
  /// - Throws: The error of the write.
  private static func writeFixture(
    named name: String, selection: SkillSelection, to destination: Destination,
    limits: SnapshotLimits = generousLimits
  ) throws -> SnapshotReport {
    try writeSnapshot(
      ofFolder: MarketplaceTestSupport.marketplaceFixture(named: name), selection: selection, layout: layout,
      limits: limits, to: destination)
  }

  /// Writes a tree into a temporary folder, then writes its full snapshot
  /// with one layout and generous limits.
  ///
  /// - Parameters:
  ///   - files: The text of each file, keyed by its path in the tree.
  ///   - layout: The layout of the tree.
  ///   - destination: The folder that the writer makes.
  /// - Returns: The report of the write.
  /// - Throws: The error of a file write, or of the snapshot write.
  private static func writeTree(
    _ files: [String: String], layout: MarketplaceLayout, to destination: Destination
  ) throws -> SnapshotReport {
    try writeSnapshot(
      ofFolder: try MarketplaceTestSupport.makeTempDirectory(withFiles: files), selection: .all, layout: layout,
      limits: generousLimits, to: destination)
  }

  // MARK: - Happy path

  @Test func aSnapshotOfAFixtureMarketplaceIsAFlatLayerRoot() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeFixture(named: Self.fixtureName, selection: .all, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(report.fileCount == Self.fixtureFileCount)
    #expect(report.byteCount > 0)
    #expect(try destination.names() == [Self.partialsName] + Self.fixtureEntryNames)
  }

  @Test(arguments: fixtureEntryNames)
  func eachEntryFolderOfTheSnapshotHoldsItsDocument(entry: String) throws {
    let destination = try Destination()
    defer { destination.remove() }

    _ = try Self.writeFixture(named: Self.fixtureName, selection: .all, to: destination)

    #expect(try destination.names(inFolder: entry).contains(Self.layout.documentName))
  }

  @Test func aSkillSelectionKeepsOnlyTheChosenSkills() throws {
    let destination = try Destination()
    defer { destination.remove() }

    _ = try Self.writeFixture(named: Self.fixtureName, selection: .skills(["tdd"]), to: destination)

    #expect(try destination.names() == [Self.partialsName, "tdd"])
  }

  @Test func thePartialsFolderOfASelectedSkillFolderIsCopied() throws {
    let destination = try Destination()
    defer { destination.remove() }

    _ = try Self.writeFixture(named: Self.fixtureName, selection: .all, to: destination)

    #expect(try destination.names(inFolder: Self.partialsName) == ["sah-task-standards.md"])
  }

  @Test func thePartialsFolderTakesTheNameOfTheLayout() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let layout = MarketplaceLayout(documentName: Self.layout.documentName, partialsDirectoryName: "_shared")

    _ = try Self.writeTree(
      [
        "skills/alpha/SKILL.md": Self.skillFile(named: "alpha"),
        "skills/_shared/note.md": "shared note",
        "skills/_partials/other.md": "not a partial of this layout",
      ], layout: layout, to: destination)

    #expect(try destination.names() == ["_shared", "alpha"])
    #expect(try destination.names(inFolder: "_shared") == ["note.md"])
  }

  @Test func aDuplicatePartialNameGivesADiagnosticAndTheLaterFolderInPathOrderWins() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(Self.twoPartialFolderTree, layout: Self.layout, to: destination)

    #expect(report.diagnostics.map(\.severity) == [.warning])
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "from second")
  }

  /// A tree with two plugin folders, each with its own
  /// `skills/_partials/shared.md`.
  private static let twoPartialFolderTree: [String: String] = [
    "first/skills/alpha/SKILL.md": skillFile(named: "alpha"),
    "first/skills/_partials/shared.md": "from first",
    "second/skills/beta/SKILL.md": skillFile(named: "beta"),
    "second/skills/_partials/shared.md": "from second",
  ]

  // MARK: - The partials of the folders above an entry

  /// One entry under the plugin folder `tools/` of each kind: the document
  /// of the entry, and the top folder that the entry gives in the snapshot.
  private static let entriesUnderAPluginFolder: [([String: String], String)] = [
    (["tools/skills/alpha/SKILL.md": skillFile(named: "alpha")], "alpha"),
    (["tools/agents/planner/AGENT.md": MarketplaceTestSupport.agentDocument(named: "planner")], agentsName),
  ]

  @Test(arguments: entriesUnderAPluginFolder)
  func thePartialsOfAFolderAboveAnEntryAreCopied(entry: [String: String], snapshotFolder: String) throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      entry.merging(["tools/_partials/note.md": "from the plugin folder"]) { $1 }, layout: Self.layout,
      to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.names() == [Self.partialsName, snapshotFolder])
    #expect(try destination.text(ofFile: "\(Self.partialsName)/note.md") == "from the plugin folder")
  }

  @Test func theSkillsPartialsReplaceTheRootPartialsWithNoDiagnostic() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      [
        "skills/alpha/SKILL.md": Self.skillFile(named: "alpha"),
        "_partials/root-only.md": "root only",
        "_partials/shared.md": "from the root",
        "skills/_partials/shared.md": "from skills",
        "skills/_partials/skills-only.md": "skills only",
      ], layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(
      try destination.names(inFolder: Self.partialsName) == ["root-only.md", "shared.md", "skills-only.md"])
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "from skills")
  }

  @Test func anAgentGetsThePartialsOfTheRoot() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      [
        "agents/planner/AGENT.md": MarketplaceTestSupport.agentDocument(named: "planner"),
        "_partials/sah-x.md": "from the root",
      ], layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.names() == [Self.partialsName, Self.agentsName])
    #expect(try destination.names(inFolder: Self.partialsName) == ["sah-x.md"])
  }

  @Test func aTreeCopiesThePartialsOfTheRoot() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      [
        "skills/alpha/SKILL.md": Self.skillFile(named: "alpha"),
        "_partials/note.md": "from the root",
      ], layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.text(ofFile: "\(Self.partialsName)/note.md") == "from the root")
  }

  @Test func aSkillFolderAtTheRootCopiesTheRootPartialsOneTime() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      [
        "alpha/SKILL.md": Self.skillFile(named: "alpha"),
        "_partials/note.md": "from the root",
      ], layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.names(inFolder: Self.partialsName) == ["note.md"])
  }

  @Test func aTreeWithNoEntryCopiesNoPartials() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(["_partials/note.md": "from the root"], layout: Self.layout, to: destination)

    #expect(report.fileCount == 0)
    #expect(!FileManager.default.fileExists(atPath: destination.folder.appendingPathComponent(Self.partialsName).path))
  }

  @Test func twoPluginFolderPartialsOfTheSameNameGiveOneDiagnosticAndTheLaterFolderWins() throws {
    let destination = try Destination()
    defer { destination.remove() }
    var tree = Self.twoPartialFolderTree
    tree["first/skills/_partials/shared.md"] = nil
    tree["second/skills/_partials/shared.md"] = nil
    tree["first/_partials/shared.md"] = "from first"
    tree["second/_partials/shared.md"] = "from second"

    let report = try Self.writeTree(tree, layout: Self.layout, to: destination)

    #expect(report.diagnostics.map(\.severity) == [.warning])
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "from second")
  }

  @Test func aMoreSpecificFileReplacesALessSpecificLinkAndNotItsTarget() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let root = try MarketplaceTestSupport.makeTempDirectory(withFiles: [
      "skills/alpha/SKILL.md": Self.skillFile(named: "alpha"),
      "_partials/target.md": "the target",
      "skills/_partials/shared.md": "from skills",
    ])
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("_partials/shared.md").path, withDestinationPath: "target.md")

    let report = try Self.writeSnapshot(
      ofFolder: root, selection: .all, layout: Self.layout, limits: Self.generousLimits, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "from skills")
    #expect(try destination.text(ofFile: "\(Self.partialsName)/target.md") == "the target")
  }

  @Test func aMoreSpecificLinkReplacesALessSpecificFile() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let root = try MarketplaceTestSupport.makeTempDirectory(withFiles: [
      "skills/alpha/SKILL.md": Self.skillFile(named: "alpha"),
      "_partials/shared.md": "from the root",
      "skills/_partials/target.md": "the skills target",
    ])
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("skills/_partials/shared.md").path, withDestinationPath: "target.md")

    let report = try Self.writeSnapshot(
      ofFolder: root, selection: .all, layout: Self.layout, limits: Self.generousLimits, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "the skills target")
  }

  @Test func aPartialsFolderInsideASkillFolderGoesWithTheSkillFolder() throws {
    let destination = try Destination()
    defer { destination.remove() }

    _ = try Self.writeTree(
      [
        "skills/alpha/SKILL.md": Self.skillFile(named: "alpha"),
        "skills/alpha/_partials/own.md": "from alpha",
      ], layout: Self.layout, to: destination)

    #expect(try destination.names() == ["alpha"])
    #expect(try destination.text(ofFile: "alpha/\(Self.partialsName)/own.md") == "from alpha")
  }

  // MARK: - The partials of nested folders

  /// A tree with one skill at `skills/group/review/`. The root, `skills/`
  /// and `skills/group/` each hold one partial of their own, and one partial
  /// with the shared name `shared.md`.
  private static let nestedSkillTree: [String: String] = [
    "skills/group/review/SKILL.md": skillFile(named: "review"),
    "_partials/root-only.md": "root only",
    "_partials/shared.md": "from the root",
    "skills/_partials/skills-only.md": "skills only",
    "skills/_partials/shared.md": "from skills",
    "skills/group/_partials/group-only.md": "group only",
    "skills/group/_partials/shared.md": "from group",
  ]

  /// The number of files that a snapshot of ``nestedSkillTree`` holds when
  /// it copies each partials folder one time: one `SKILL.md` file, and two
  /// partials for each of the three folders.
  private static let nestedSkillFileCount = 7

  @Test func aNestedSkillGetsThePartialsOfEachFolderFromTheRootDown() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(Self.nestedSkillTree, layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(
      try destination.names(inFolder: Self.partialsName)
        == ["group-only.md", "root-only.md", "shared.md", "skills-only.md"])
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "from group")
  }

  @Test func eachPartialsFolderOfANestedSkillIsCopiedOneTime() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(Self.nestedSkillTree, layout: Self.layout, to: destination)

    #expect(report.fileCount == Self.nestedSkillFileCount)
  }

  @Test func theMostSpecificCopyWinsWhenAShallowerSkillIsBeside() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      [
        "skills/group/review/SKILL.md": Self.skillFile(named: "review"),
        "skills/top/SKILL.md": Self.skillFile(named: "top"),
        "skills/_partials/shared.md": "from skills",
        "skills/group/_partials/shared.md": "from group",
      ], layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "from group")
  }

  @Test func twoFoldersAtTheSameLevelGiveOneDiagnosticAndTheLaterFolderWins() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      [
        "skills/group-a/alpha/SKILL.md": Self.skillFile(named: "alpha"),
        "skills/group-b/beta/SKILL.md": Self.skillFile(named: "beta"),
        "skills/group-a/_partials/x.md": "from group-a",
        "skills/group-b/_partials/x.md": "from group-b",
      ], layout: Self.layout, to: destination)

    #expect(report.diagnostics.map(\.severity) == [.warning])
    #expect(try destination.text(ofFile: "\(Self.partialsName)/x.md") == "from group-b")
  }

  /// The text of one fixture `SKILL.md` file.
  ///
  /// - Parameter name: The frontmatter name of the skill.
  /// - Returns: The text of the file.
  private static func skillFile(named name: String) -> String {
    """
    ---
    name: \(name)
    description: A fixture skill of the snapshot writer tests.
    ---

    The body of \(name).
    """
  }

  // MARK: - Agents

  /// The agents folder of a layer root.
  private static let agentsName = MarketplaceLayer.agentsDirectoryName

  /// The fixture of the `swissarmyhammer/skills` shape: `skills/`,
  /// `skills/_partials/` and `agents/` side by side at the root.
  private static let agentsFixtureName = "swissarmyhammer-agents"

  /// The agent folders of ``agentsFixtureName``, in name order.
  private static let agentsFixtureAgentNames = [
    "committer", "double-check", "explorer", "general-purpose", "implementer", "planner", "reviewer", "tester",
  ]

  /// The number of files of a tree with one skill document and one agent
  /// document.
  private static let oneSkillFileAndOneAgentFile = 2

  /// A tree with one skill and one agent.
  private static let oneSkillAndOneAgentTree: [String: String] = [
    "skills/alpha/SKILL.md": skillFile(named: "alpha"),
    "agents/planner/AGENT.md": MarketplaceTestSupport.agentDocument(named: "planner"),
  ]

  /// The pattern of a Stencil include tag. The one capture is the included
  /// path.
  ///
  /// A `Regex` is not `Sendable`, thus the pattern is a computed property
  /// and not a stored one.
  private static var includePattern: Regex<(Substring, Substring)> {
    #/\{% include "([^"]+)" %\}/#
  }

  /// The extension that an included partial path leaves out.
  private static let partialExtension = ".md"

  @Test func theSnapshotHoldsAgentsSlashNameForEachAgentFolder() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(MarketplaceTestSupport.twoPluginAgentTree, layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.names() == [Self.agentsName, "alpha", "beta"])
    #expect(try destination.names(inFolder: Self.agentsName) == ["planner", "reviewer"])
    #expect(
      try destination.text(ofFile: "\(Self.agentsName)/reviewer/\(Self.agentDocumentName)")
        == MarketplaceTestSupport.agentDocument(named: "reviewer"))
  }

  @Test func theAgentFolderThatWinsTheScanIsInTheSnapshot() throws {
    let destination = try Destination()
    defer { destination.remove() }
    var tree = MarketplaceTestSupport.twoPluginAgentTree
    tree["first/agents/reviewer/AGENT.md"] = "from first"

    _ = try Self.writeTree(tree, layout: Self.layout, to: destination)

    #expect(try destination.text(ofFile: "\(Self.agentsName)/reviewer/\(Self.agentDocumentName)") == "from first")
  }

  @Test func anAgentFolderIsCopiedAsATree() throws {
    let destination = try Destination()
    defer { destination.remove() }

    _ = try Self.writeTree(
      [
        "agents/lead/AGENT.md": MarketplaceTestSupport.agentDocument(named: "lead"),
        "agents/lead/checklist.md": "a resource",
        "agents/lead/data/table.txt": "a nested resource",
      ], layout: Self.layout, to: destination)

    #expect(try destination.names(inFolder: "\(Self.agentsName)/lead") == ["AGENT.md", "checklist.md", "data"])
    #expect(try destination.text(ofFile: "\(Self.agentsName)/lead/data/table.txt") == "a nested resource")
  }

  @Test func anAgentDocumentIsCopiedByteForByte() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let text = "---\nname: [\n---\n\nNo frontmatter that parses.\n"

    _ = try Self.writeTree(["agents/broken/AGENT.md": text], layout: Self.layout, to: destination)

    #expect(try destination.text(ofFile: "\(Self.agentsName)/broken/\(Self.agentDocumentName)") == text)
  }

  @Test func theReportCountsEachAgentFile() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(Self.oneSkillAndOneAgentTree, layout: Self.layout, to: destination)

    #expect(report.fileCount == Self.oneSkillFileAndOneAgentFile)
  }

  @Test func anAgentFileAboveTheFileLimitIsRejectedAndNoFolderStays() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let limits = SnapshotLimits(maxBytes: Self.generousLimits.maxBytes, maxFiles: Self.limitOfOne)

    #expect(throws: SnapshotError.tooManyFiles(path: "agents/planner/AGENT.md", limit: Self.limitOfOne)) {
      _ = try Self.writeSnapshot(
        ofFolder: try MarketplaceTestSupport.makeTempDirectory(withFiles: Self.oneSkillAndOneAgentTree),
        selection: .all, layout: Self.layout, limits: limits, to: destination)
    }
    #expect(!destination.folderExists)
  }

  @Test func aSkillFolderNamedAgentsIsNotCopied() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(
      [
        "skills/agents/SKILL.md": Self.skillFile(named: "agents"),
        "skills/alpha/SKILL.md": Self.skillFile(named: "alpha"),
      ], layout: Self.layout, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.names() == ["alpha"])
  }

  @Test func theSwissarmyhammerShapeGivesEachAgentAndThePartials() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeFixture(named: Self.agentsFixtureName, selection: .all, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.names() == [Self.partialsName, Self.agentsName, "code-context", "review"])
    #expect(try destination.names(inFolder: Self.agentsName) == Self.agentsFixtureAgentNames)
    #expect(
      try destination.names(inFolder: Self.partialsName)
        == ["sah-architecture-awareness.md", "sah-findings-are-requirements.md"])
  }

  @Test(arguments: agentsFixtureAgentNames)
  func eachAgentOfTheSwissarmyhammerShapeFindsThePartialThatItIncludes(agent: String) throws {
    let destination = try Destination()
    defer { destination.remove() }
    _ = try Self.writeFixture(named: Self.agentsFixtureName, selection: .all, to: destination)

    let text = try destination.text(ofFile: "\(Self.agentsName)/\(agent)/\(Self.agentDocumentName)")
    let included = text.matches(of: Self.includePattern).map { String($0.output.1) + Self.partialExtension }

    #expect(!included.isEmpty)
    #expect(included.allSatisfy { FileManager.default.fileExists(atPath: destination.folder.appendingPathComponent($0).path) })
  }

  @Test func thePluginLayoutGivesEachAgentFolderItsResourcesAndThePluginPartials() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeFixture(named: "agent-library", selection: .all, to: destination)

    #expect(report.diagnostics.isEmpty)
    #expect(try destination.names() == [Self.partialsName, Self.agentsName, "review"])
    #expect(try destination.names(inFolder: Self.agentsName) == ["doc-writer", "security-reviewer"])
    #expect(
      try destination.names(inFolder: "\(Self.agentsName)/security-reviewer") == ["AGENT.md", "checklist.md"])
    #expect(try destination.names(inFolder: Self.partialsName) == ["house-rules.md"])
  }

  // MARK: - The execute bit

  @Test func anExecutableFileKeepsModeSevenFiveFive() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneEntry(
      holding: [
        CatalogTreeEntry(name: "SKILL.md", kind: .file(isExecutable: false)),
        CatalogTreeEntry(name: "run.sh", kind: .file(isExecutable: true)),
      ],
      files: ["SKILL.md": Self.skillFile(named: "tool"), "run.sh": "#!/bin/sh\necho hello\n"])

    _ = try Self.write(tree, to: destination)

    let attributes = try FileManager.default.attributesOfItem(
      atPath: destination.folder.appendingPathComponent("tool/run.sh").path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == Self.executablePermissions)
  }

  @Test func aPlainFileDoesNotGetTheExecuteBit() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneEntry(
      holding: [CatalogTreeEntry(name: "SKILL.md", kind: .file(isExecutable: false))],
      files: ["SKILL.md": Self.skillFile(named: "tool")])

    _ = try Self.write(tree, to: destination)

    let document = destination.folder.appendingPathComponent("tool/SKILL.md").path
    #expect(!FileManager.default.isExecutableFile(atPath: document))
  }

  // MARK: - Rejections

  @Test(arguments: ["..", "a..b", ".", "a/b", "a\\b", "", "tab\tname"])
  func anUnsafeEntryNameIsRejectedAndNoFolderStays(name: String) throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneEntry(holding: [CatalogTreeEntry(name: name, kind: .file(isExecutable: false))])

    #expect(throws: SnapshotError.unsafeEntryName(directory: "tool", name: name)) {
      _ = try Self.write(tree, to: destination)
    }
    #expect(!destination.folderExists)
  }

  @Test(
    arguments: ["../../outside.md", "../outside.md", "/etc/passwd", "~/secret", "sub/../../outside.md"],
    [MemoryEntryKind.skill, .agent])
  func aSymlinkThatLeavesItsEntryFolderIsRejectedAndNoFolderStays(target: String, kind: MemoryEntryKind) throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneEntry(holding: [CatalogTreeEntry(name: "link.md", kind: .symlink(target: target))], kind: kind)

    #expect(throws: SnapshotError.escapingSymlink(path: "tool/link.md", target: target)) {
      _ = try Self.write(tree, to: destination)
    }
    #expect(!destination.folderExists)
  }

  @Test func aSymlinkThatStaysInTheSkillFolderIsCopied() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneEntry(
      holding: [
        CatalogTreeEntry(name: "SKILL.md", kind: .file(isExecutable: false)),
        CatalogTreeEntry(name: "link.md", kind: .symlink(target: "SKILL.md")),
      ],
      files: ["SKILL.md": Self.skillFile(named: "tool")])

    _ = try Self.write(tree, to: destination)

    let link = destination.folder.appendingPathComponent("tool/link.md").path
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "SKILL.md")
  }

  @Test func aSubmoduleEntryIsRejectedAndNoFolderStays() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneEntry(holding: [CatalogTreeEntry(name: "vendor", kind: .submodule)])

    #expect(throws: SnapshotError.submodule(path: "tool/vendor")) {
      _ = try Self.write(tree, to: destination)
    }
    #expect(!destination.folderExists)
  }

  // MARK: - Limits

  @Test func aFileCountAboveTheLimitIsRejectedAndNoFolderStays() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let limits = SnapshotLimits(maxBytes: Self.generousLimits.maxBytes, maxFiles: Self.limitOfOne)

    #expect(
      throws: SnapshotError.tooManyFiles(path: Self.fixtureSecondFilePath, limit: Self.limitOfOne)
    ) {
      _ = try Self.writeFixture(
        named: Self.fixtureName, selection: .all, to: destination, limits: limits)
    }
    #expect(!destination.folderExists)
  }

  @Test func aByteCountAboveTheLimitIsRejectedAndNoFolderStays() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let limits = SnapshotLimits(maxBytes: Self.limitOfOne, maxFiles: Self.generousLimits.maxFiles)

    #expect(
      throws: SnapshotError.tooManyBytes(path: Self.fixtureFirstFilePath, limit: Self.limitOfOne)
    ) {
      _ = try Self.writeFixture(
        named: Self.fixtureName, selection: .all, to: destination, limits: limits)
    }
    #expect(!destination.folderExists)
  }

  @Test func theReportCountsTheFilesAndTheBytes() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let document = Self.skillFile(named: "tool")
    let tree = Self.oneEntry(
      holding: [
        CatalogTreeEntry(name: "SKILL.md", kind: .file(isExecutable: false)),
        CatalogTreeEntry(name: "link.md", kind: .symlink(target: "SKILL.md")),
      ],
      files: ["SKILL.md": document])

    let report = try Self.write(tree, to: destination)

    #expect(report == SnapshotReport(fileCount: Self.oneFileAndOneLink, byteCount: document.utf8.count, diagnostics: []))
  }

  /// The file count of a snapshot with one file and one symbolic link: the
  /// link counts as one file with no bytes.
  private static let oneFileAndOneLink = 2

  // MARK: - Large file storage

  @Test func aLargeFileStoragePointerIsWrittenAndGivesADiagnostic() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let pointer = """
      \(SnapshotWriter.largeFileStoragePrefix)
      oid sha256:0123456789abcdef
      size 12345

      """
    let tree = Self.oneEntry(
      holding: [
        CatalogTreeEntry(name: "SKILL.md", kind: .file(isExecutable: false)),
        CatalogTreeEntry(name: "diagram.png", kind: .file(isExecutable: false)),
      ],
      files: ["SKILL.md": Self.skillFile(named: "tool"), "diagram.png": pointer])

    let report = try Self.write(tree, to: destination)

    #expect(report.diagnostics.map(\.severity) == [.warning])
    #expect(report.diagnostics.first?.message.contains("tool/diagram.png") == true)
    #expect(try destination.text(ofFile: "tool/diagram.png") == pointer)
  }

  // MARK: - Error descriptions

  /// Each snapshot error, with the sentence that it describes itself with.
  private static let snapshotErrorDescriptions: [(error: SnapshotError, text: String)] = [
    (
      .unsafeEntryName(directory: "", name: ".."),
      #"The folder "." holds the name "..", which cannot go into a snapshot path."#
    ),
    (.escapingSymlink(path: "t/l", target: "../x"), #"The link "t/l" points to "../x", which is outside its entry folder."#),
    (.submodule(path: "t/vendor"), #"The entry "t/vendor" is a git submodule, which a snapshot cannot hold."#),
    (.tooManyFiles(path: "t/f", limit: limitOfOne), #"The snapshot reached the limit of \#(limitOfOne) files at "t/f"."#),
    (.tooManyBytes(path: "t/f", limit: limitOfOne), #"The snapshot reached the limit of \#(limitOfOne) bytes at "t/f"."#),
  ]

  @Test(arguments: snapshotErrorDescriptions)
  func eachSnapshotErrorDescribesItself(error: SnapshotError, text: String) {
    #expect(error.description == text)
  }
}
