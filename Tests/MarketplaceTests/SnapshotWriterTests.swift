import FixtureSupport
import Foundation
import Testing

@testable import Marketplace

/// Proves the snapshot writer of marketplace.md §7.3 steps 3 and 4: one flat
/// folder that holds `<entry>/` for each selected entry and the partials
/// folder that the layout names, the execute bit, the validation rules, and
/// the diagnostics.
///
/// Each test writes into its own temporary folder, so no test reads the files
/// of another test. The happy path reads a fixture catalog through
/// ``LocalCatalogFileSource``. The rejection tests read an in-memory source,
/// because a folder on the disk cannot hold a submodule entry and a test
/// should not need a name that the file system itself refuses.
@Suite("Marketplace snapshot writer")
struct SnapshotWriterTests {
  // MARK: - Fixture

  /// The fixture catalog of the happy path: three skills and one partial.
  private static let fixtureName = "swissarmyhammer-skills"

  /// The entry folders of a full snapshot of ``fixtureName``, in name
  /// order, after the partials folder.
  private static let fixtureEntryNames = ["code-context", "commit", "tdd"]

  /// The number of files that a full snapshot of ``fixtureName`` holds:
  /// three `SKILL.md` files, one extra file of the `tdd` skill, and one
  /// partial.
  private static let fixtureFileCount = 5

  /// The tree path of the first file that a full snapshot of
  /// ``fixtureName`` copies. The catalog lists `code-context` first.
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

  /// The layout of the tests: `SKILL.md` marks an entry, and the partials
  /// folder has the default name.
  private static let layout = MarketplaceTestSupport.skillsLayout

  /// The partials folder name of ``layout``.
  private static let partialsName = layout.partialsDirectoryName

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

  /// Makes a source and a catalog of one skill folder that holds the given
  /// items, for the rejection tests.
  ///
  /// - Parameters:
  ///   - entries: The items of the skill folder.
  ///   - files: The text of each file of the skill folder, keyed by its
  ///     name. The default is no file.
  /// - Returns: The source and the catalog that names the one skill.
  private static func oneSkill(
    holding entries: [CatalogTreeEntry], files: [String: String] = [:]
  ) -> (source: MemoryCatalogFileSource, catalog: ResolvedCatalog) {
    let folder = "tool"
    let source = MemoryCatalogFileSource(
      files: Dictionary(uniqueKeysWithValues: files.map { ("\(folder)/\($0.key)", $0.value) }),
      listings: [folder: entries])
    let catalog = ResolvedCatalog(
      name: "memory", version: nil,
      skills: [ResolvedSkill(name: folder, path: folder, plugin: nil)],
      renames: [:], diagnostics: [])
    return (source, catalog)
  }

  /// Writes a snapshot of one in-memory tree with the test layout and
  /// generous limits.
  ///
  /// - Parameters:
  ///   - tree: The source and the catalog of the tree.
  ///   - destination: The folder that the writer makes.
  /// - Returns: The report of the write.
  /// - Throws: The error of the write.
  private static func write(
    _ tree: (source: MemoryCatalogFileSource, catalog: ResolvedCatalog), to destination: Destination
  ) throws -> SnapshotReport {
    try SnapshotWriter.write(
      catalog: tree.catalog, from: tree.source, to: destination.folder, layout: layout, limits: generousLimits)
  }

  /// Resolves the catalog of a folder on the disk and writes its snapshot.
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

  /// Writes a snapshot of one fixture catalog with the test layout.
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
      ofFolder: MarketplaceTestSupport.catalogFixture(named: name), selection: selection, layout: layout,
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

  @Test func aSnapshotOfAFixtureCatalogIsAFlatLayerRoot() throws {
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

  @Test func aDuplicatePartialNameGivesADiagnosticAndTheLaterFolderWins() throws {
    let destination = try Destination()
    defer { destination.remove() }

    let report = try Self.writeTree(Self.twoPartialFolderTree, layout: Self.layout, to: destination)

    #expect(report.diagnostics.map(\.severity) == [.warning])
    #expect(try destination.text(ofFile: "\(Self.partialsName)/shared.md") == "from second")
  }

  /// A tree with two plugins, each with its own `_partials/shared.md`.
  private static let twoPartialFolderTree: [String: String] = [
    ".claude-plugin/marketplace.json": """
      {
        "name": "two-plugins",
        "plugins": [
          { "name": "first", "source": "./first" },
          { "name": "second", "source": "./second" }
        ]
      }
      """,
    "first/skills/alpha/SKILL.md": skillFile(named: "alpha"),
    "first/skills/_partials/shared.md": "from first",
    "second/skills/beta/SKILL.md": skillFile(named: "beta"),
    "second/skills/_partials/shared.md": "from second",
  ]

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

  // MARK: - The execute bit

  @Test func anExecutableFileKeepsModeSevenFiveFive() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneSkill(
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
    let tree = Self.oneSkill(
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
    let tree = Self.oneSkill(holding: [CatalogTreeEntry(name: name, kind: .file(isExecutable: false))])

    #expect(throws: SnapshotError.unsafeEntryName(directory: "tool", name: name)) {
      _ = try Self.write(tree, to: destination)
    }
    #expect(!destination.folderExists)
  }

  @Test(arguments: ["../../outside.md", "../outside.md", "/etc/passwd", "~/secret", "sub/../../outside.md"])
  func aSymlinkThatLeavesTheSkillFolderIsRejectedAndNoFolderStays(target: String) throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneSkill(holding: [CatalogTreeEntry(name: "link.md", kind: .symlink(target: target))])

    #expect(throws: SnapshotError.escapingSymlink(path: "tool/link.md", target: target)) {
      _ = try Self.write(tree, to: destination)
    }
    #expect(!destination.folderExists)
  }

  @Test func aSymlinkThatStaysInTheSkillFolderIsCopied() throws {
    let destination = try Destination()
    defer { destination.remove() }
    let tree = Self.oneSkill(
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
    let tree = Self.oneSkill(holding: [CatalogTreeEntry(name: "vendor", kind: .submodule)])

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
    let tree = Self.oneSkill(
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
    let tree = Self.oneSkill(
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
    (.escapingSymlink(path: "t/l", target: "../x"), #"The link "t/l" points to "../x", which is outside its skill folder."#),
    (.submodule(path: "t/vendor"), #"The entry "t/vendor" is a git submodule, which a snapshot cannot hold."#),
    (.tooManyFiles(path: "t/f", limit: limitOfOne), #"The snapshot reached the limit of \#(limitOfOne) files at "t/f"."#),
    (.tooManyBytes(path: "t/f", limit: limitOfOne), #"The snapshot reached the limit of \#(limitOfOne) bytes at "t/f"."#),
  ]

  @Test(arguments: snapshotErrorDescriptions)
  func eachSnapshotErrorDescribesItself(error: SnapshotError, text: String) {
    #expect(error.description == text)
  }
}
