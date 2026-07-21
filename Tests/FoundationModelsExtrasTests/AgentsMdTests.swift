import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `AgentsMd.documents(from:upTo:)`: alias preference
/// per directory, one-file-per-directory, outermost-first/nearest-last
/// ordering, `.git` root detection vs an explicit `root:`, the walk
/// stopping at `root`, symlinked-alias dedupe, and empty results (plan.md
/// §10). Every test builds its own throwaway directory tree under a temp
/// directory so nothing ever touches the real home directory or a real
/// `.git` repository above the fixture.
@Suite struct AgentsMdTests {
  /// A throwaway directory tree, cleaned up when the OS reclaims the temp
  /// directory. Canonicalized once at creation (see `TestSupport.swift`'s
  /// `canonicalize`) so later URL/path equality checks match what
  /// `AgentsMd`'s own `realpath(3)`-based canonicalization returns.
  struct Fixture {
    let root: URL

    init() {
      let uncanonicalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentsMdTests-\(UUID().uuidString)", isDirectory: true)
      try! FileManager.default.createDirectory(
        at: uncanonicalRoot, withIntermediateDirectories: true)
      root = canonicalize(uncanonicalRoot)
    }

    /// Creates `relativePath` (and any intermediate directories) under the
    /// fixture root.
    func mkdir(_ relativePath: String) -> URL {
      let url = root.appendingPathComponent(relativePath, isDirectory: true)
      try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    /// Writes `contents` to `relativePath` under the fixture root, creating
    /// any intermediate directories.
    @discardableResult
    func write(_ contents: String, to relativePath: String) -> URL {
      let fileURL = root.appendingPathComponent(relativePath)
      try! FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL
    }

    /// Creates a symbolic link at `relativePath` under the fixture root,
    /// pointing at `destination` (given relative to `relativePath`'s own
    /// directory, exactly as `ln -s destination relativePath` would take
    /// it).
    func symlink(_ relativePath: String, to destination: String) {
      let linkURL = root.appendingPathComponent(relativePath)
      try! FileManager.default.createDirectory(
        at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try! FileManager.default.createSymbolicLink(
        atPath: linkURL.path, withDestinationPath: destination)
    }

  }

  // MARK: - Alias preference per directory

  @Test func aliasPreferencePicksAgentsMdOverAgentMdAndClaudeMd() throws {
    let fixture = Fixture()
    fixture.write("agents", to: "AGENTS.md")
    fixture.write("agent", to: "AGENT.md")
    fixture.write("claude", to: "CLAUDE.md")

    let documents = try AgentsMd.documents(from: fixture.root, upTo: fixture.root)

    #expect(documents.count == 1)
    #expect(documents.first?.text == "agents")
    #expect(documents.first?.url == fixture.root.appendingPathComponent("AGENTS.md"))
  }

  @Test func aliasPreferencePicksAgentMdWhenAgentsMdMissing() throws {
    let fixture = Fixture()
    fixture.write("agent", to: "AGENT.md")
    fixture.write("claude", to: "CLAUDE.md")

    let documents = try AgentsMd.documents(from: fixture.root, upTo: fixture.root)

    #expect(documents.count == 1)
    #expect(documents.first?.text == "agent")
    #expect(documents.first?.url == fixture.root.appendingPathComponent("AGENT.md"))
  }

  @Test func aliasPreferencePicksClaudeMdWhenOnlyClaudeMdPresent() throws {
    let fixture = Fixture()
    fixture.write("claude", to: "CLAUDE.md")

    let documents = try AgentsMd.documents(from: fixture.root, upTo: fixture.root)

    #expect(documents.count == 1)
    #expect(documents.first?.text == "claude")
    #expect(documents.first?.url == fixture.root.appendingPathComponent("CLAUDE.md"))
  }

  @Test func aDirectoryWithNoAliasContributesNoDocument() throws {
    let fixture = Fixture()
    let leaf = fixture.mkdir("leaf")
    fixture.write("root doc", to: "AGENTS.md")

    let documents = try AgentsMd.documents(from: leaf, upTo: fixture.root)

    #expect(documents.count == 1)
    #expect(documents.first?.directory == fixture.root)
  }

  // MARK: - Ordering: outermost-first, nearest-last

  @Test func documentsAreReturnedOutermostFirstNearestLast() throws {
    let fixture = Fixture()
    let mid = fixture.mkdir("mid")
    let leaf = fixture.mkdir("mid/leaf")
    fixture.write("root", to: "AGENTS.md")
    fixture.write("mid", to: "mid/AGENTS.md")
    fixture.write("leaf", to: "mid/leaf/AGENTS.md")

    let documents = try AgentsMd.documents(from: leaf, upTo: fixture.root)

    #expect(documents.map(\.text) == ["root", "mid", "leaf"])
    #expect(documents.map(\.directory) == [fixture.root, mid, leaf])
  }

  // MARK: - `.git` root detection vs explicit `root:`

  @Test func gitRootDetectionFindsNearestAncestorContainingADotGitEntry() throws {
    let fixture = Fixture()
    fixture.write("outside", to: "AGENTS.md")
    let repo = fixture.mkdir("repo")
    _ = fixture.mkdir("repo/.git")
    fixture.write("repo", to: "repo/AGENTS.md")
    let sub = fixture.mkdir("repo/sub")
    fixture.write("sub", to: "repo/sub/AGENTS.md")
    let leaf = fixture.mkdir("repo/sub/leaf")

    let documents = try AgentsMd.documents(from: leaf)

    #expect(documents.map(\.text) == ["repo", "sub"])
    #expect(documents.map(\.directory) == [repo, sub])
  }

  @Test func explicitRootOverridesGitDetectionAndWalksPastANearerDotGit() throws {
    let fixture = Fixture()
    fixture.write("fixtureRoot", to: "AGENTS.md")
    let repo = fixture.mkdir("repo")
    _ = fixture.mkdir("repo/.git")
    fixture.write("repo", to: "repo/AGENTS.md")
    let leaf = fixture.mkdir("repo/leaf")
    fixture.write("leaf", to: "repo/leaf/AGENTS.md")

    let documents = try AgentsMd.documents(from: leaf, upTo: fixture.root)

    #expect(documents.map(\.text) == ["fixtureRoot", "repo", "leaf"])
    #expect(documents.map(\.directory) == [fixture.root, repo, leaf])
  }

  @Test func walkStopsAtRootAndNeverReadsAboveIt() throws {
    let fixture = Fixture()
    fixture.write("outside", to: "AGENTS.md")
    let insideRoot = fixture.mkdir("inside")
    fixture.write("inside", to: "inside/AGENTS.md")

    let documents = try AgentsMd.documents(from: insideRoot, upTo: insideRoot)

    #expect(documents.map(\.text) == ["inside"])
  }

  // MARK: - Symlink dedupe

  @Test func sameDirectorySymlinkAliasIsNeverReadBecauseAgentsMdWinsFirst() throws {
    let fixture = Fixture()
    fixture.write("agents", to: "AGENTS.md")
    fixture.symlink("AGENT.md", to: "AGENTS.md")

    let documents = try AgentsMd.documents(from: fixture.root, upTo: fixture.root)

    #expect(documents.count == 1)
    #expect(documents.first?.text == "agents")
    #expect(documents.first?.url == fixture.root.appendingPathComponent("AGENTS.md"))
  }

  @Test func crossDirectorySymlinkResolvingToAnAlreadyIncludedFileIsDeduped() throws {
    let fixture = Fixture()
    fixture.write("shared", to: "AGENTS.md")
    let child = fixture.mkdir("child")
    fixture.symlink("child/AGENTS.md", to: "../AGENTS.md")

    let documents = try AgentsMd.documents(from: child, upTo: fixture.root)

    #expect(documents.count == 1)
    #expect(documents.first?.text == "shared")
    #expect(documents.first?.directory == child)
    #expect(documents.first?.url == child.appendingPathComponent("AGENTS.md"))
  }

  // MARK: - Empty results

  @Test func emptyResultsWhenNoAliasFilesExistAndWorkingDirectoryEqualsRoot() throws {
    let fixture = Fixture()

    let documents = try AgentsMd.documents(from: fixture.root, upTo: fixture.root)

    #expect(documents.isEmpty)
  }

  @Test func emptyResultsAcrossMultipleLevelsWithNoAliasFilesAnywhere() throws {
    let fixture = Fixture()
    let leaf = fixture.mkdir("a/b/c")

    let documents = try AgentsMd.documents(from: leaf, upTo: fixture.root)

    #expect(documents.isEmpty)
  }

  // MARK: - Error surface

  @Test func throwsFileNotReadableWhenTheMatchedAliasIsNotValidUTF8() throws {
    let fixture = Fixture()
    let fileURL = fixture.root.appendingPathComponent("AGENTS.md")
    let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
    try! invalidUTF8.write(to: fileURL)

    #expect(throws: AgentsMdError.self) {
      _ = try AgentsMd.documents(from: fixture.root, upTo: fixture.root)
    }
  }
}
