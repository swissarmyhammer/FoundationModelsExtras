import Foundation
import MarketplaceFixtures
import Testing
import libgit2

@testable import Marketplace

/// Proves ``GitTreeFileSource`` over commits that ``GitFixtureRepository``
/// writes with libgit2 (marketplace.md §5.1 and §7.3).
///
/// The source reads the tree and blob objects of a commit. There is no
/// checkout, no network, and no `git` binary. The parity tests commit each
/// fixture catalog of `Tests/MarketplaceTests/Fixtures/catalogs/` and prove
/// that the resolver gives the same result over the tree as over the folder.
@Suite("Git tree file source")
struct GitTreeFileSourceTests {
  /// The catalog fixtures that the parity tests read.
  private static let catalogFixtures = [
    "anthropics-skills", "claude-and-codex", "claude-plugins-official", "codex-catalog", "duplicate-skills",
    "nameless-root", "remote-plugins", "renamed-skills", "repository-scan", "single-skill-repository",
    "swissarmyhammer-skills",
  ]

  /// The subfolder that the root-path tests put a tree in.
  private static let subfolder = "nested"

  // MARK: - Files

  @Test func aSourceReadsTheBytesOfAFile() throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["folder/inner.txt": .file("inner")])

    let source = try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit)

    #expect(try source.contents(atPath: "folder/inner.txt") == Data("inner".utf8))
  }

  @Test func aSourceReadsAnEmptyFile() throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["empty.txt": .file("")])

    let source = try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit)

    #expect(try source.contents(atPath: "empty.txt") == Data())
  }

  @Test(arguments: ["missing.txt", "folder/missing.txt", "folder", "", "link", "module"])
  func aSourceGivesNilForAPathThatIsNotAFile(path: String) throws {
    let source = try Self.sourceOfEveryMode()

    #expect(try source.contents(atPath: path) == nil)
  }

  @Test func aSourceDoesNotFollowASymlinkInAPath() throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["real/inner.txt": .file("inner"), "alias": .symlink(target: "real")])

    let source = try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit)

    #expect(try source.contents(atPath: "alias/inner.txt") == nil)
  }

  // MARK: - Folders

  @Test func theKindOfEachItemFollowsItsMode() throws {
    let fixture = try GitFixtureRepository()
    let earlier = try fixture.commit(files: ["README.md": .file("first")])
    let commit = try fixture.commit(files: Self.treeOfEveryMode(submoduleCommit: earlier))

    let entries = try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit).entries(inDirectory: "")

    #expect(
      entries == [
        CatalogTreeEntry(name: "folder", kind: .directory),
        CatalogTreeEntry(name: "link", kind: .symlink(target: "plain.txt")),
        CatalogTreeEntry(name: "module", kind: .submodule),
        CatalogTreeEntry(name: "plain.txt", kind: .file(isExecutable: false)),
        CatalogTreeEntry(name: "run.sh", kind: .file(isExecutable: true)),
      ])
  }

  @Test func aSourceListsASubfolder() throws {
    let source = try Self.sourceOfEveryMode()

    #expect(
      try source.entries(inDirectory: "folder") == [CatalogTreeEntry(name: "inner.txt", kind: .file(isExecutable: false))]
    )
  }

  @Test func aFolderListIsInNameOrderAndNotInGitOrder() throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["a-b": .file("file"), "a/inner.txt": .file("inner")])

    let entries = try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit).entries(inDirectory: "")

    #expect(entries.map(\.name) == ["a", "a-b"])
  }

  @Test(arguments: ["missing", "folder/inner.txt", "link", "module"])
  func aSourceGivesNoEntriesForAPathThatIsNotAFolder(path: String) throws {
    let source = try Self.sourceOfEveryMode()

    #expect(try source.entries(inDirectory: path).isEmpty)
  }

  // MARK: - The root path

  @Test func theRootPathIsAPrefixOnEachRead() throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["nested/inner.txt": .file("inner"), "outside.txt": .file("outside")])

    let source = try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit, rootPath: Self.subfolder)

    #expect(try source.contents(atPath: "inner.txt") == Data("inner".utf8))
    #expect(try source.contents(atPath: "outside.txt") == nil)
  }

  @Test func theRootPathIsAPrefixOnEachList() throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["nested/inner.txt": .file("inner"), "outside.txt": .file("outside")])

    let source = try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit, rootPath: Self.subfolder)

    #expect(try source.entries(inDirectory: "") == [CatalogTreeEntry(name: "inner.txt", kind: .file(isExecutable: false))])
  }

  @Test(arguments: ["../outside", "/etc", "~/secret"])
  func aRootPathOutsideTheTreeIsRefused(rootPath: String) throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["README.md": .file("first")])

    #expect(throws: CatalogFileSourceError.pathOutsideRoot(rootPath)) {
      try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit, rootPath: rootPath)
    }
  }

  // MARK: - Refused paths and failures

  @Test(arguments: ["../outside.txt", "/etc/hosts", "~/secret"])
  func aReadOfAPathOutsideTheTreeIsRefused(path: String) throws {
    let source = try Self.sourceOfEveryMode()

    #expect(throws: CatalogFileSourceError.pathOutsideRoot(path)) {
      try source.contents(atPath: path)
    }
  }

  @Test(arguments: ["../outside", "/etc", "~/secret"])
  func aListOfAPathOutsideTheTreeIsRefused(path: String) throws {
    let source = try Self.sourceOfEveryMode()

    #expect(throws: CatalogFileSourceError.pathOutsideRoot(path)) {
      try source.entries(inDirectory: path)
    }
  }

  @Test func aCommitThatTheRepositoryDoesNotHoldThrowsNotFound() throws {
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: ["README.md": .file("first")])
    let other = try GitFixtureRepository()
    let source = try GitTreeFileSource(repositoryURL: other.directory, commit: commit)

    let error = try #require(throws: GitTransportError.self) {
      try source.contents(atPath: "README.md")
    }

    #expect(Self.code(of: error) == GIT_ENOTFOUND.rawValue)
  }

  // MARK: - Parity with a folder on the disk

  @Test(arguments: catalogFixtures)
  func theResolverGivesTheSameResultAsOverAFolder(fixture name: String) throws {
    let folder = MarketplaceTestSupport.catalogFixture(named: name)
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(files: try Self.textFiles(inFolder: folder).mapValues { .file($0) })

    let fromTree = CatalogResolver.resolve(
      from: try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit), selection: .all,
      layout: MarketplaceTestSupport.skillsLayout)
    let fromFolder = CatalogResolver.resolve(
      from: LocalCatalogFileSource(root: folder), selection: .all, layout: MarketplaceTestSupport.skillsLayout)

    #expect(fromTree == fromFolder)
  }

  @Test(arguments: catalogFixtures)
  func theResolverUnderARootPathGivesTheSameResultAsOverAFolder(fixture name: String) throws {
    let folder = MarketplaceTestSupport.catalogFixture(named: name)
    let files = try Self.textFiles(inFolder: folder)
    let fixture = try GitFixtureRepository()
    let commit = try fixture.commit(
      files: Dictionary(uniqueKeysWithValues: files.map { ("\(Self.subfolder)/\($0.key)", .file($0.value)) })
        .merging(["README.md": .file("outside the root path")]) { kept, _ in kept })

    let fromTree = CatalogResolver.resolve(
      from: try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit, rootPath: Self.subfolder),
      selection: .all, layout: MarketplaceTestSupport.skillsLayout)
    let fromFolder = CatalogResolver.resolve(
      from: LocalCatalogFileSource(root: folder), selection: .all, layout: MarketplaceTestSupport.skillsLayout)

    #expect(fromTree == fromFolder)
  }

  // MARK: - Helpers

  /// A tree with one item of each mode: a folder, a symbolic link, a
  /// submodule, a regular file, and an executable file.
  ///
  /// - Parameter submoduleCommit: The 40-hex SHA that the submodule entry
  ///   names.
  /// - Returns: The tree, one entry for each path.
  private static func treeOfEveryMode(submoduleCommit: String) -> [String: GitFixtureRepository.Entry] {
    [
      "plain.txt": .file("plain"),
      "run.sh": .executable("echo hi"),
      "link": .symlink(target: "plain.txt"),
      "folder/inner.txt": .file("inner"),
      "module": .submodule(commit: submoduleCommit),
    ]
  }

  /// Makes a source over a new fixture commit of ``treeOfEveryMode(submoduleCommit:)``.
  ///
  /// The source keeps the repository directory, and the fixture removes it
  /// when the fixture is released. Thus each test that uses this source
  /// keeps the fixture alive in the returned value.
  ///
  /// - Returns: The source over the commit.
  /// - Throws: The error of a fixture step.
  private static func sourceOfEveryMode() throws -> FixtureBackedSource {
    let fixture = try GitFixtureRepository()
    let earlier = try fixture.commit(files: ["README.md": .file("first")])
    let commit = try fixture.commit(files: treeOfEveryMode(submoduleCommit: earlier))
    return FixtureBackedSource(
      fixture: fixture, source: try GitTreeFileSource(repositoryURL: fixture.directory, commit: commit))
  }

  /// Reads the text of each regular file under a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The text of each file, keyed by its path in the folder.
  /// - Throws: The error of the folder walk or of a file read.
  private static func textFiles(inFolder folder: URL) throws -> [String: String] {
    let paths = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
    return try Dictionary(
      uniqueKeysWithValues: paths.filter { Self.isRegularFile(atPath: folder.appendingPathComponent($0).path) }
        .map { ($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) })
  }

  /// Tells whether a regular file, and not a folder, is at a path.
  ///
  /// - Parameter path: The path on the disk.
  /// - Returns: `true` for a regular file.
  private static func isRegularFile(atPath path: String) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.type] as? FileAttributeType == .typeRegular
  }

  /// Gives the libgit2 code of a ``GitTransportError/libgit2(code:message:)``
  /// error.
  ///
  /// - Parameter error: The error.
  /// - Returns: The code, or `nil` for another case.
  private static func code(of error: GitTransportError) -> Int32? {
    guard case .libgit2(let code, _) = error else {
      return nil
    }
    return code
  }
}

/// A ``GitTreeFileSource`` that holds its fixture repository, thus the
/// repository stays on the disk while a test reads it.
private struct FixtureBackedSource {
  /// The fixture that owns the repository directory.
  let fixture: GitFixtureRepository

  /// The source over one commit of the fixture.
  let source: GitTreeFileSource

  /// Reads the bytes of one file through ``source``.
  ///
  /// - Parameter path: The path of the file.
  /// - Returns: The bytes, or `nil` when no file is at the path.
  /// - Throws: The error of ``source``.
  func contents(atPath path: String) throws -> Data? {
    try source.contents(atPath: path)
  }

  /// Lists one folder through ``source``.
  ///
  /// - Parameter path: The path of the folder.
  /// - Returns: The items of the folder.
  /// - Throws: The error of ``source``.
  func entries(inDirectory path: String) throws -> [CatalogTreeEntry] {
    try source.entries(inDirectory: path)
  }
}
