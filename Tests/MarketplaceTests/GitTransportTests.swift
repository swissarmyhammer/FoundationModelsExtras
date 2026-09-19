import FixtureSupport
import Foundation
import MarketplaceFixtures
import Testing
import libgit2

@testable import Marketplace

/// Proves the libgit2 ``LibGit2Transport`` against fixture repositories over
/// `file://` URLs (marketplace.md §5.1 and §13), and the read of a fetched
/// commit tree through ``GitTreeFileSource``.
///
/// Each fixture is a repository that ``GitFixtureRepository`` builds with
/// libgit2, thus the suite needs no network and no `git` binary.
@Suite("Git transport")
struct GitTransportTests {
  /// The transport under test, reached through the protocol that the
  /// marketplace store uses.
  private let transport: any GitTransport = LibGit2Transport()

  /// The HTTPS source that the credentials callback tests serve.
  private static let httpsSourceURL = "https://git.example.com/owner/skills.git"

  /// The credential that the credentials callback tests give. The values are
  /// plain fixture text.
  private static let credential = MarketplaceCredential(username: "fixture-user", token: "fixture-token")

  /// The path of the one file that the tree read tests commit.
  private static let skillPath = "skills/commit/SKILL.md"

  /// The text of the file at ``skillPath``.
  private static let skillBody = "body"

  /// A 40-hex SHA that no fixture repository holds, for a submodule entry.
  private static let submoduleCommit = "0123456789abcdef0123456789abcdef01234567"

  // MARK: - remoteHead

  @Test func remoteHeadGivesTheTipOfABranch() async throws {
    let fixture = try GitFixtureRepository()
    let tip = try fixture.commit(files: ["README.md": .file("first")])

    let head = try await transport.remoteHead(url: fixture.url, ref: "main", credentials: nil)

    #expect(head == tip)
  }

  @Test func remoteHeadGivesTheCommitOfALightweightTag() async throws {
    let fixture = try GitFixtureRepository()
    let tagged = try fixture.commit(files: ["README.md": .file("first")])
    try fixture.commit(files: ["README.md": .file("second")])
    try fixture.addLightweightTag(named: "v1.0.0", at: tagged)

    let head = try await transport.remoteHead(url: fixture.url, ref: "v1.0.0", credentials: nil)

    #expect(head == tagged)
  }

  @Test func remoteHeadGivesTheCommitThatAnAnnotatedTagPeelsTo() async throws {
    let fixture = try GitFixtureRepository()
    let tagged = try fixture.commit(files: ["README.md": .file("first")])
    try fixture.commit(files: ["README.md": .file("second")])
    try fixture.addAnnotatedTag(named: "v2.0.0", at: tagged)

    let head = try await transport.remoteHead(url: fixture.url, ref: "v2.0.0", credentials: nil)

    #expect(head == tagged)
  }

  @Test func remoteHeadGivesTheCommitThatHEADNames() async throws {
    let fixture = try GitFixtureRepository()
    let tip = try fixture.commit(files: ["README.md": .file("first")])

    let head = try await transport.remoteHead(url: fixture.url, ref: "HEAD", credentials: nil)

    #expect(head == tip)
  }

  @Test func remoteHeadThrowsRefNotFoundForAMissingRef() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: ["README.md": .file("first")])

    await #expect(throws: GitTransportError.refNotFound) {
      try await transport.remoteHead(url: fixture.url, ref: "missing", credentials: nil)
    }
  }

  @Test func remoteHeadThrowsUnreachableWithTheLibgit2MessageForAMissingPath() async throws {
    let parent = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: parent) }
    let absent = parent.appendingPathComponent("absent", isDirectory: true).absoluteString

    let error = try await #require(throws: GitTransportError.self) {
      try await transport.remoteHead(url: absent, ref: "main", credentials: nil)
    }

    let message = try #require(Self.unreachableMessage(of: error), "expected unreachable, got \(error)")
    #expect(message.contains("absent"), "the libgit2 message names the path that failed; got: \(message)")
  }

  // MARK: - fetch

  @Test func fetchPutsTheBranchTipInANewBareRepository() async throws {
    let fixture = try GitFixtureRepository()
    let tip = try fixture.commit(files: [Self.skillPath: .file(Self.skillBody), "run.sh": .executable("echo")])
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }

    let fetched = try await transport.fetch(
      url: fixture.url, revision: "main", intoBareRepository: destination, credentials: nil)

    #expect(fetched == tip)
    #expect(try GitFixtureRepository.containsCommit(sha: tip, inRepositoryAt: destination))
  }

  @Test func fetchGetsTheNewerCommitAfterTheBranchMoves() async throws {
    let fixture = try GitFixtureRepository()
    let first = try fixture.commit(files: ["README.md": .file("first")])
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }
    let firstFetch = try await transport.fetch(
      url: fixture.url, revision: "main", intoBareRepository: destination, credentials: nil)
    let newer = try fixture.commit(
      files: ["README.md": .file("newer"), "link": .symlink(target: "README.md")], on: "next")
    try fixture.moveBranch(named: "main", to: newer)

    let secondFetch = try await transport.fetch(
      url: fixture.url, revision: "main", intoBareRepository: destination, credentials: nil)

    #expect(firstFetch == first)
    #expect(secondFetch == newer)
    #expect(try GitFixtureRepository.containsCommit(sha: newer, inRepositoryAt: destination))
  }

  @Test func fetchOfAPinnedSHAGivesThatCommit() async throws {
    let fixture = try GitFixtureRepository()
    let pinned = try fixture.commit(files: ["README.md": .file("first")])
    try fixture.commit(files: ["README.md": .file("second")])
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }

    let fetched = try await transport.fetch(
      url: fixture.url, revision: pinned, intoBareRepository: destination, credentials: nil)

    #expect(fetched == pinned)
    #expect(try GitFixtureRepository.containsCommit(sha: pinned, inRepositoryAt: destination))
  }

  @Test func fetchOfAnAnnotatedTagGivesTheCommit() async throws {
    let fixture = try GitFixtureRepository()
    let tagged = try fixture.commit(files: ["README.md": .file("first")])
    try fixture.addAnnotatedTag(named: "v2.0.0", at: tagged)
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }

    let fetched = try await transport.fetch(
      url: fixture.url, revision: "v2.0.0", intoBareRepository: destination, credentials: nil)

    #expect(fetched == tagged)
  }

  @Test func fetchOfAMissingRefThrowsRefNotFound() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: ["README.md": .file("first")])
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }

    await #expect(throws: GitTransportError.refNotFound) {
      try await transport.fetch(
        url: fixture.url, revision: "missing", intoBareRepository: destination, credentials: nil)
    }
  }

  @Test func fetchThrowsUnreachableWithTheLibgit2MessageForAMissingPath() async throws {
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }
    let absent = destination.deletingLastPathComponent()
      .appendingPathComponent("absent", isDirectory: true).absoluteString

    let error = try await #require(throws: GitTransportError.self) {
      try await transport.fetch(url: absent, revision: "main", intoBareRepository: destination, credentials: nil)
    }

    let message = try #require(Self.unreachableMessage(of: error), "expected unreachable, got \(error)")
    #expect(message.contains("absent"), "the libgit2 message names the path that failed; got: \(message)")
  }

  @Test func fetchInACancelledTaskThrowsCancelled() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: ["README.md": .file("first")])
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }
    let url = fixture.url
    let transport = transport

    let fetch = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await transport.fetch(url: url, revision: "main", intoBareRepository: destination, credentials: nil)
    }

    await #expect(throws: GitTransportError.cancelled) {
      try await fetch.value
    }
  }

  // MARK: - Tree read of a fetched commit

  @Test func aFetchedCommitGivesTheBytesOfAFileInItsTree() async throws {
    let fetched = try await fetchTree(files: [Self.skillPath: .file(Self.skillBody)])
    defer { fetched.remove() }

    #expect(try fetched.source.contents(atPath: Self.skillPath) == Data(Self.skillBody.utf8))
  }

  @Test func aFetchedCommitGivesNoBytesForAPathThatIsNotAFile() async throws {
    let fetched = try await fetchTree(files: [Self.skillPath: .file(Self.skillBody), "link": .symlink(target: "skills")])
    defer { fetched.remove() }

    #expect(try fetched.source.contents(atPath: "skills") == nil)
    #expect(try fetched.source.contents(atPath: "link") == nil)
    #expect(try fetched.source.contents(atPath: "missing.md") == nil)
  }

  @Test func aFetchedCommitListsTheEntriesOfAFolderInItsTreeByName() async throws {
    let fetched = try await fetchTree(files: [
      Self.skillPath: .file(Self.skillBody),
      "skills/run.sh": .executable("echo"),
      "skills/link": .symlink(target: "run.sh"),
      "skills/vendor": .submodule(commit: Self.submoduleCommit),
      "skills/README.md": .file("readme"),
    ])
    defer { fetched.remove() }

    let entries = try fetched.source.entries(inDirectory: "skills")

    #expect(
      entries == [
        CatalogTreeEntry(name: "README.md", kind: .file(isExecutable: false)),
        CatalogTreeEntry(name: "commit", kind: .directory),
        CatalogTreeEntry(name: "link", kind: .symlink(target: "run.sh")),
        CatalogTreeEntry(name: "run.sh", kind: .file(isExecutable: true)),
        CatalogTreeEntry(name: "vendor", kind: .submodule),
      ])
  }

  @Test func aFetchedCommitListsNoEntryForAPathThatIsNotAFolder() async throws {
    let fetched = try await fetchTree(files: [Self.skillPath: .file(Self.skillBody)])
    defer { fetched.remove() }

    #expect(try fetched.source.entries(inDirectory: Self.skillPath).isEmpty)
    #expect(try fetched.source.entries(inDirectory: "missing").isEmpty)
  }

  @Test func theEmptyPathListsTheRootOfTheTree() async throws {
    let fetched = try await fetchTree(files: [Self.skillPath: .file(Self.skillBody), "README.md": .file("readme")])
    defer { fetched.remove() }

    let names = try fetched.source.entries(inDirectory: "").map(\.name)

    #expect(names == ["README.md", "skills"])
  }

  @Test func aRootPathMakesASubfolderTheRootOfEveryLookup() async throws {
    let fetched = try await fetchTree(files: [Self.skillPath: .file(Self.skillBody)], rootPath: "./skills")
    defer { fetched.remove() }

    #expect(try fetched.source.contents(atPath: "commit/SKILL.md") == Data(Self.skillBody.utf8))
    #expect(try fetched.source.entries(inDirectory: "").map(\.name) == ["commit"])
  }

  @Test(arguments: ["/skills", "~/skills", "../skills", "skills/../.."])
  func aRootPathOutsideTheTreeIsRefused(rootPath: String) throws {
    let repository = URL(fileURLWithPath: "/", isDirectory: true)

    #expect(throws: CatalogFileSourceError.pathOutsideRoot(rootPath)) {
      try GitTreeFileSource(repositoryURL: repository, commit: Self.submoduleCommit, rootPath: rootPath)
    }
  }

  @Test func aLookupPathOutsideTheTreeIsRefused() async throws {
    let fetched = try await fetchTree(files: [Self.skillPath: .file(Self.skillBody)])
    defer { fetched.remove() }

    #expect(throws: CatalogFileSourceError.pathOutsideRoot("../etc/passwd")) {
      try fetched.source.contents(atPath: "../etc/passwd")
    }
  }

  @Test func aCommitThatTheRepositoryDoesNotHoldFailsAtTheFirstRead() async throws {
    let fetched = try await fetchTree(files: [Self.skillPath: .file(Self.skillBody)])
    defer { fetched.remove() }
    let source = try GitTreeFileSource(repositoryURL: fetched.destination, commit: Self.submoduleCommit)

    let error = try #require(throws: GitTransportError.self) {
      try source.contents(atPath: Self.skillPath)
    }

    #expect(Self.isLibgit2Failure(error), "expected a libgit2 failure, got \(error)")
  }

  // MARK: - Shallow fetch and the retry

  @Test func aShallowFetchThatIsNotSupportedIsTriedAgainWithFullDepth() {
    var depths: [Int32] = []

    let status = LibGit2Transport.fetchShallowFirst { depth in
      depths.append(depth)
      return depth == LibGit2Transport.shallowDepth ? GIT_ENOTSUPPORTED.rawValue : GIT_OK.rawValue
    }

    #expect(depths == [LibGit2Transport.shallowDepth, LibGit2Transport.fullDepth])
    #expect(status == GIT_OK.rawValue)
  }

  @Test(arguments: [
    GIT_OK.rawValue, GIT_ERROR.rawValue, GIT_ENOTFOUND.rawValue, GIT_EUSER.rawValue, GIT_TIMEOUT.rawValue,
  ])
  func aShallowFetchIsTriedAgainOnlyWhenNotSupported(status: Int32) {
    var depths: [Int32] = []

    let result = LibGit2Transport.fetchShallowFirst { depth in
      depths.append(depth)
      return status
    }

    #expect(depths == [LibGit2Transport.shallowDepth])
    #expect(result == status)
  }

  // MARK: - Credentials

  @Test func aFileSourceFetchesWithNoCredentialRequest() async throws {
    let fixture = try GitFixtureRepository()
    let tip = try fixture.commit(files: ["README.md": .file("first")])
    let destination = try Self.makeDestination()
    defer { Self.removeDestination(destination) }
    let requests = CredentialRequestRecorder()

    let fetched = try await transport.fetch(
      url: fixture.url, revision: "main", intoBareRepository: destination,
      credentials: requests.provider(giving: Self.credential))

    #expect(fetched == tip)
    #expect(await requests.requestedURLs.isEmpty)
  }

  @Test func theCredentialsCallbackGivesTheCredentialOneTime() throws {
    // `git_credential_userpass_plaintext_new` needs libgit2 started. A
    // call through `fetch` or `remoteHead` starts it before it reaches
    // the credentials callback; this test calls the callback directly,
    // thus it starts libgit2 itself first.
    try LibGit2Transport.check(status: LibGit2Transport.libraryStartCount, phase: .localRepository)

    var gate = CredentialGate(sourceURL: Self.httpsSourceURL, credential: Self.credential)
    var first: UnsafeMutablePointer<git_credential>?
    var second: UnsafeMutablePointer<git_credential>?

    let statuses = withUnsafeMutablePointer(to: &gate) { gate in
      [
        LibGit2Transport.credentialStatus(into: &first, requestURL: Self.httpsSourceURL, gate: gate),
        LibGit2Transport.credentialStatus(into: &second, requestURL: Self.httpsSourceURL, gate: gate),
      ]
    }
    defer { git_credential_free(first) }
    let given: UnsafeMutablePointer<git_credential> = try #require(first)

    #expect(statuses == [GIT_OK.rawValue, GIT_EUSER.rawValue])
    #expect(String(cString: git_credential_get_username(given)) == Self.credential.username)
    #expect(second == nil)
  }

  @Test func theCredentialsCallbackRefusesARequestFromAnotherOrigin() {
    var gate = CredentialGate(sourceURL: Self.httpsSourceURL, credential: Self.credential)
    var given: UnsafeMutablePointer<git_credential>?

    let status = withUnsafeMutablePointer(to: &gate) { gate in
      LibGit2Transport.credentialStatus(
        into: &given, requestURL: "https://other.example.com/owner/skills.git", gate: gate)
    }

    #expect(status == GIT_EUSER.rawValue)
    #expect(given == nil)
  }

  // MARK: - Error mapping

  @Test(arguments: LibGit2Transport.Phase.allCases)
  func aStopFromAProgressCallbackIsCancelled(phase: LibGit2Transport.Phase) {
    let error = LibGit2Transport.transportError(code: GIT_EUSER.rawValue, message: "stopped", phase: phase)

    #expect(error == .cancelled)
  }

  @Test(arguments: LibGit2Transport.Phase.allCases)
  func aStopFromARefusedCredentialRequestIsUnreachableWithTheFixedMessage(phase: LibGit2Transport.Phase) {
    let error = LibGit2Transport.transportError(
      code: GIT_EUSER.rawValue, message: "stopped", phase: phase, credentialRefused: true)

    #expect(error == .unreachable(message: LibGit2Transport.credentialRefusedMessage))
  }

  @Test(arguments: LibGit2Transport.Phase.allCases)
  func aTimeoutFromTheNetworkIsTimedOut(phase: LibGit2Transport.Phase) {
    let error = LibGit2Transport.transportError(code: GIT_TIMEOUT.rawValue, message: "timed out", phase: phase)

    #expect(error == .timedOut)
  }

  @Test(arguments: ["failed to resolve address", "unsupported URL protocol"])
  func anyOtherConnectFailureIsUnreachableWithTheLibgit2Message(message: String) {
    let error = LibGit2Transport.transportError(code: GIT_ERROR.rawValue, message: message, phase: .connecting)

    #expect(error == .unreachable(message: message))
  }

  @Test func theTextOfAnUnreachableErrorSaysTheLibgit2Message() {
    let error = GitTransportError.unreachable(message: "unsupported URL protocol")

    #expect(String(describing: error).contains("unsupported URL protocol"))
  }

  @Test func aMissingObjectDuringTheFetchIsRefNotFound() {
    let error = LibGit2Transport.transportError(
      code: GIT_ENOTFOUND.rawValue, message: "object not found", phase: .fetching)

    #expect(error == .refNotFound)
  }

  @Test(arguments: [LibGit2Transport.Phase.fetching, .localRepository])
  func anyOtherFailureKeepsTheLibgit2CodeAndMessage(phase: LibGit2Transport.Phase) {
    let error = LibGit2Transport.transportError(code: GIT_ERROR.rawValue, message: "disk full", phase: phase)

    #expect(error == .libgit2(code: GIT_ERROR.rawValue, message: "disk full"))
  }

  // MARK: - Support

  /// A commit fetched into a new bare repository, with a tree source over
  /// it.
  private struct FetchedTree {
    /// The bare repository that holds the fetched commit.
    let destination: URL

    /// The source over the tree of the fetched commit, through the protocol
    /// that the catalog resolver reads.
    let source: any CatalogFileSource

    /// Removes the temporary directory of ``destination``.
    func remove() {
      removeDestination(destination)
    }
  }

  /// Commits `files` in a new fixture, fetches `main` into a new bare
  /// repository, and opens a tree source over the fetched commit.
  ///
  /// - Parameters:
  ///   - files: The tree of the one fixture commit.
  ///   - rootPath: The `rootPath` of the source, or `nil` for the root of
  ///     the commit tree.
  /// - Returns: The fetched commit and its source. The caller removes it.
  private func fetchTree(files: [String: GitFixtureRepository.Entry], rootPath: String? = nil) async throws
    -> FetchedTree
  {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: files)
    let destination = try Self.makeDestination()
    let fetched = try await transport.fetch(
      url: fixture.url, revision: "main", intoBareRepository: destination, credentials: nil)
    return FetchedTree(
      destination: destination,
      source: try GitTreeFileSource(repositoryURL: destination, commit: fetched, rootPath: rootPath))
  }

  /// A path for a bare repository that does not exist yet, in a new
  /// temporary directory.
  private static func makeDestination() throws -> URL {
    try TemporaryDirectory.make().appendingPathComponent("repo.git", isDirectory: true)
  }

  /// Gives the message of a ``GitTransportError/unreachable(message:)``
  /// error.
  ///
  /// - Parameter error: The error.
  /// - Returns: The message, or `nil` for another case.
  private static func unreachableMessage(of error: GitTransportError) -> String? {
    guard case .unreachable(let message) = error else {
      return nil
    }
    return message
  }

  /// Tells whether an error is the
  /// ``GitTransportError/libgit2(code:message:)`` case.
  ///
  /// - Parameter error: The error.
  /// - Returns: `true` for a libgit2 failure with a code and a message.
  private static func isLibgit2Failure(_ error: GitTransportError) -> Bool {
    if case .libgit2 = error {
      return true
    }
    return false
  }

  /// Removes the temporary directory that ``makeDestination()`` made.
  private static func removeDestination(_ destination: URL) {
    try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
  }
}
