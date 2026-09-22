import FixtureSupport
import Foundation
import MarketplaceFixtures
import Testing

@testable import Marketplace

/// Tests for the git half of ``MarketplaceStore`` (marketplace.md §6.1, §6.2,
/// §7.3, and §7.6).
///
/// Every test builds a repository with ``GitFixtureRepository`` and reads it
/// over a `file://` URL with the real ``LibGit2Transport``, thus the suite
/// needs no network and no `git` binary. Each store writes into a temporary
/// cache of its own. A test that proves what a consumer sees reads the skill
/// document under the layer root, as a consumer does.
@Suite("Marketplace store")
struct MarketplaceStoreTests {
  /// How long a test waits, after the expected layer updates arrived, to
  /// confirm that no further value follows them.
  private static let noFurtherSignalWindow: Duration = .milliseconds(500)

  /// The display id of a fixture marketplace, which is its repository name.
  private static let fixtureID = "fixture"

  /// The name of the symlink that a layer root of a git marketplace ends in.
  private static let currentLinkName = "current"

  /// The name of the folder that holds one folder for each snapshot, under
  /// the folder of one marketplace.
  private static let snapshotsDirectoryName = "snapshots"

  /// How many layer updates two swaps publish.
  private static let updatesAfterTwoSwaps = 2

  /// The credential that the credentials test gives. The values are plain
  /// fixture text.
  private static let credential = MarketplaceCredential(username: "fixture-user", token: "fixture-token")

  // MARK: - Cold start

  @Test func aColdStartMakesTheFixtureSkillReadableUnderTheLayerRoot() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])

    await cache.store.start()

    #expect(try Self.skillBody(ofFirstLayer: cache.store).contains("alpha body"))
  }

  @Test func aColdStartGivesALayerWithTheStableCurrentRootAndTheProvenance() async throws {
    let fixture = try GitFixtureRepository()
    let head = try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    let rootBeforeStart = try #require(cache.store.marketplaceLayers().first).layer.root

    await cache.store.start()

    let layer = try #require(cache.store.marketplaceLayers().first)
    #expect(layer.layer.source == .marketplace)
    #expect(layer.layer.root == rootBeforeStart)
    #expect(layer.layer.root.lastPathComponent == Self.currentLinkName)
    #expect(layer.provenance.id == Self.fixtureID)
    #expect(layer.provenance.url == fixture.url)
    #expect(layer.provenance.sha == head)
    #expect(layer.provenance.catalogVersion == nil)
  }

  @Test func aSecondStartWithNoRemoteChangeDoesNoFetch() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let transport = RecordingGitTransport()
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)], transport: transport)

    await cache.store.start()
    await cache.store.start()

    #expect(await transport.fetchCount == 1)
    #expect(await transport.remoteHeadCount == 2)
  }

  @Test func eachSwapPublishesOneLayerUpdateAndACheckPublishesNone() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    let tally = LayerUpdateTally()
    let subscription = tally.follow(cache.store.layerUpdates)
    defer { subscription.cancel() }

    await cache.store.start()
    _ = await cache.store.check()
    await cache.store.update()
    try fixture.commit(files: Self.skillTree(body: "alpha body v2"))
    await cache.store.update()

    let count = await tally.settledCount(atLeast: Self.updatesAfterTwoSwaps, window: Self.noFurtherSignalWindow)
    #expect(count == Self.updatesAfterTwoSwaps)
  }

  // MARK: - Update

  @Test func aNewCommitAndAnUpdateSwapTheCurrentSnapshot() async throws {
    let fixture = try GitFixtureRepository()
    let first = try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    await cache.store.start()
    let second = try fixture.commit(files: Self.skillTree(body: "alpha body v2"))

    let events = await cache.store.update()

    #expect(events == [.updated(id: Self.fixtureID, from: first, to: second)])
    #expect(cache.store.marketplaceLayers().first?.provenance.sha == second)
    #expect(try Self.skillBody(ofFirstLayer: cache.store).contains("alpha body v2"))
  }

  @Test func anUnreachableRemoteKeepsTheLastGoodSnapshot() async throws {
    let fixture = try GitFixtureRepository()
    let head = try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    await cache.store.start()
    let restarted = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], cacheDirectory: cache.cacheDirectory,
      transport: UnreachableGitTransport())

    let events = await restarted.store.update(force: true)

    #expect(events.count == 1)
    #expect(MarketplaceTestSupport.keptVersion(ofFirst: events) == head)
    #expect(restarted.store.marketplaceLayers().first?.provenance.sha == head)
    #expect(try Self.skillBody(ofFirstLayer: restarted.store).contains("alpha body"))
  }

  @Test func theDefaultInitReadsTheSnapshotThatAnEarlierStoreInstalled() async throws {
    let fixture = try GitFixtureRepository()
    let head = try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    await cache.store.start()

    let store = MarketplaceStore(
      sources: [MarketplaceSource(fixture.url)], layout: MarketplaceStoreFixture.skillsLayout,
      cacheDirectory: cache.cacheDirectory)

    #expect(store.marketplaceLayers().first?.provenance.sha == head)
    #expect(try Self.skillBody(ofFirstLayer: store).contains("alpha body"))
  }

  // MARK: - Layers

  @Test func aCatalogSourceGivesALayerThatHoldsItsAgentsBesideItsSkillsAndPartials() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.agentCatalogTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])

    await cache.store.start()

    let root = try #require(cache.store.marketplaceLayers().first).layer.root
    let agents = root.appendingPathComponent(MarketplaceLayer.agentsDirectoryName, isDirectory: true)
    #expect(
      try String(contentsOf: agents.appendingPathComponent(Self.agentFileName), encoding: .utf8)
        == MarketplaceTestSupport.agentDocument(named: Self.agentName))
    #expect(try Self.skillBody(ofFirstLayer: cache.store).contains("alpha body"))
    #expect(
      try String(contentsOf: root.appendingPathComponent(Self.partialPath), encoding: .utf8) == Self.partialText)
  }

  @Test func theLayersComeInListOrderLowestFirst() async throws {
    let first = try GitFixtureRepository()
    try first.commit(files: Self.skillTree(body: "first"))
    let second = try GitFixtureRepository()
    try second.commit(files: Self.skillTree(body: "second"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(first.url, alias: "one"), MarketplaceSource(second.url, alias: "two")])

    await cache.store.start()

    #expect(cache.store.marketplaceLayers().map(\.provenance.id) == ["one", "two"])
    #expect(cache.store.marketplaceLayers().map(\.provenance.url) == [first.url, second.url])
  }

  @Test func aDuplicatePreFetchKeyRefusesTheWholeList() async throws {
    let first = try GitFixtureRepository()
    try first.commit(files: Self.skillTree(body: "first"))
    let second = try GitFixtureRepository()
    try second.commit(files: Self.skillTree(body: "second"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(first.url), MarketplaceSource(second.url)])

    await cache.store.start()

    #expect(cache.store.marketplaceLayers().isEmpty)
    #expect(cache.store.diagnostics.contains { $0.severity == .error && $0.message.contains("pre-fetch key") })
  }

  // MARK: - Locks

  @Test func theSnapshotThatOneStoreServesSurvivesCleanupByASecondStore() async throws {
    let fixture = try GitFixtureRepository()
    let first = try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    await cache.store.start()
    let other = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], cacheDirectory: cache.cacheDirectory)

    try fixture.commit(files: Self.skillTree(body: "alpha body v2"))
    await other.store.update()
    try fixture.commit(files: Self.skillTree(body: "alpha body v3"))
    await other.store.update()

    #expect(cache.store.marketplaceLayers().first?.provenance.sha == first)
    #expect(try Self.skillBody(ofFirstLayer: cache.store).contains("alpha body"))
  }

  @Test func theStoreHoldsALeaseOnTheSnapshotItServesAndReleasesTheOneItLeaves() async throws {
    let fixture = try GitFixtureRepository()
    let first = try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    await cache.store.start()
    let second = try fixture.commit(files: Self.skillTree(body: "alpha body v2"))

    await cache.store.update()

    let layer = try #require(cache.store.marketplaceLayers().first)
    let snapshots = layer.layer.root.deletingLastPathComponent()
      .appendingPathComponent(Self.snapshotsDirectoryName, isDirectory: true)
    #expect(SnapshotLockProbe.isLocked(directory: snapshots.appendingPathComponent(second, isDirectory: true)))
    #expect(!SnapshotLockProbe.isLocked(directory: snapshots.appendingPathComponent(first, isDirectory: true)))
  }

  // MARK: - Credentials and the display id

  @Test func theCredentialsClosureOfThePolicyReachesTheFetch() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let transport = RecordingGitTransport()
    let policy = MarketplacePolicy(credentials: { _ in Self.credential })
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], policy: policy, transport: transport)

    await cache.store.start()

    #expect(await transport.fetchCredentials == [Self.credential])
  }

  @Test func twoSourcesWithTheSameCatalogNameGiveADiagnostic() async throws {
    let first = try GitFixtureRepository()
    try first.commit(files: Self.catalogTree(name: "shared", body: "first"))
    let second = try GitFixtureRepository()
    try second.commit(files: Self.catalogTree(name: "shared", body: "second"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(first.url, alias: "one"), MarketplaceSource(second.url, alias: "two")],
      transport: RecordingGitTransport())

    await cache.store.start()

    #expect(cache.store.marketplaceLayers().map(\.provenance.id) == ["shared", "shared"])
    #expect(cache.store.diagnostics.contains { $0.message.contains(#"the display id "shared""#) })
  }

  // MARK: - Support

  /// Counts the values of a ``MarketplaceLayerProviding/layerUpdates``
  /// stream, and lets a test wait for a count.
  private actor LayerUpdateTally {
    /// How many values arrived so far.
    private var count = 0

    /// Starts a task that counts every value of one stream.
    ///
    /// - Parameter stream: The stream to follow.
    /// - Returns: The task, which the test cancels when it is done.
    nonisolated func follow(_ stream: AsyncStream<Void>) -> Task<Void, Never> {
      Task {
        for await _ in stream {
          await self.record()
        }
      }
    }

    /// Waits until at least `expected` values arrived, then waits one more
    /// window so that a value that follows them has time to arrive.
    ///
    /// The store publishes each value before the call that swaps returns,
    /// thus the window only gives the counting task time to read the
    /// buffered values.
    ///
    /// - Parameters:
    ///   - expected: The count that the test waits for.
    ///   - window: How long the wait after the expected count is.
    /// - Returns: The count after the window.
    func settledCount(atLeast expected: Int, window: Duration) async -> Int {
      while count < expected {
        await Task.yield()
      }
      try? await Task.sleep(for: window)
      return count
    }

    /// Counts one value.
    private func record() {
      count += 1
    }
  }

  /// A ``GitTransport`` whose remote is never reachable, as a host that is
  /// down or a network that is off.
  ///
  /// The double fails before any libgit2 work, thus the URL of the source
  /// and the cache folder that it names stay the same as for the store that
  /// installed the snapshot.
  private actor UnreachableGitTransport: GitTransport {
    /// The message of every failure.
    private static let message = "the fixture remote is down"

    func remoteHead(
      url: String, ref: String, credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
    ) async throws -> String {
      throw GitTransportError.unreachable(message: Self.message)
    }

    func fetch(
      url: String, revision: String, intoBareRepository repositoryURL: URL,
      credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
    ) async throws -> String {
      throw GitTransportError.unreachable(message: Self.message)
    }
  }

  /// Reads the body of the fixture skill under the root of the first layer
  /// of a store.
  ///
  /// - Parameter store: The store.
  /// - Returns: The text of the skill document.
  /// - Throws: A failed requirement when the store has no layer, else the
  ///   error of the file read.
  private static func skillBody(ofFirstLayer store: MarketplaceStore) throws -> String {
    try MarketplaceTestSupport.skillBody(inLayerRoot: try #require(store.marketplaceLayers().first).layer.root)
  }

  /// The tree of a fixture that has no catalog: one skill folder that a
  /// repository scan finds.
  ///
  /// - Parameter body: The body of the skill.
  /// - Returns: The tree, one entry for each path.
  private static func skillTree(body: String) -> [String: GitFixtureRepository.Entry] {
    MarketplaceTestSupport.skillTree(body: body)
  }

  /// The tree of a fixture that has a Claude catalog with one plugin.
  ///
  /// - Parameters:
  ///   - name: The `name` field of the catalog, which becomes the display
  ///     id of the marketplace.
  ///   - body: The body of the skill.
  /// - Returns: The tree, one entry for each path.
  private static func catalogTree(name: String, body: String) -> [String: GitFixtureRepository.Entry] {
    let skillPath = "./\(MarketplaceTestSupport.skillsFolderName)/\(MarketplaceTestSupport.fixtureSkillID)"
    let catalog = """
      {"name": "\(name)", "plugins": [{"name": "p", "source": "./", "skills": ["\(skillPath)"]}]}
      """
    return skillTree(body: body).merging([".claude-plugin/marketplace.json": .file(catalog)]) { _, later in later }
  }

  /// The name of the agent of ``agentCatalogTree(body:)``.
  private static let agentName = "reviewer"

  /// The file name of the agent of ``agentCatalogTree(body:)``.
  private static let agentFileName = "\(agentName).md"

  /// The partial of ``agentCatalogTree(body:)``, relative to the layer root.
  private static let partialPath = "\(MarketplaceLayout.defaultPartialsDirectoryName)/sah-rules.md"

  /// The text of the partial of ``agentCatalogTree(body:)``.
  private static let partialText = "Fixture rules."

  /// The tree of a fixture in the shape of the `swissarmyhammer/skills`
  /// marketplace: a Claude catalog with one plugin at the root, one skill,
  /// one partial beside the skill, and one agent in `agents/`.
  ///
  /// - Parameter body: The body of the skill.
  /// - Returns: The tree, one entry for each path.
  private static func agentCatalogTree(body: String) -> [String: GitFixtureRepository.Entry] {
    catalogTree(name: fixtureID, body: body).merging([
      "\(MarketplaceTestSupport.skillsFolderName)/\(partialPath)": .file(partialText),
      "\(MarketplaceLayer.agentsDirectoryName)/\(agentFileName)":
        .file(MarketplaceTestSupport.agentDocument(named: agentName)),
    ]) { _, later in later }
  }
}
