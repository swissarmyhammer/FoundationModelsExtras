import FixtureSupport
import Foundation
import MarketplaceFixtures
import Testing

@testable import Marketplace

/// Tests for the git half of ``MarketplaceStore``.
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

  /// The catalog `name` that a state file of an earlier version holds.
  private static let earlierDisplayID = "other-name"

  /// The catalog `version` that a state file of an earlier version holds.
  private static let earlierCatalogVersion = "9.9.9"

  /// How many first characters of a commit the display text of a
  /// provenance shows.
  private static let shortShaLength = 7

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

  @Test func aSourceGivesALayerThatHoldsItsAgentFoldersBesideItsSkillsAndPartials() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.agentTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])

    await cache.store.start()

    let root = try #require(cache.store.marketplaceLayers().first).layer.root
    let agents = root.appendingPathComponent(MarketplaceLayer.agentsDirectoryName, isDirectory: true)
    #expect(
      try String(contentsOf: agents.appendingPathComponent(Self.agentDocumentPath), encoding: .utf8)
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

  @Test func aCatalogFileInTheTreeDoesNotChangeTheDisplayText() async throws {
    let fixture = try GitFixtureRepository()
    let catalog =
      #"{"name": "\#(Self.earlierDisplayID)", "metadata": {"version": "\#(Self.earlierCatalogVersion)"}, "plugins": []}"#
    let head = try fixture.commit(
      files: Self.skillTree(body: "alpha body").merging([".claude-plugin/marketplace.json": .file(catalog)]) {
        _, later in later
      })
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])

    await cache.store.start()

    let layer = try #require(cache.store.marketplaceLayers().first)
    #expect(layer.provenance.displayText == Self.displayText(ofCommit: head))
    #expect(try Self.skillBody(ofFirstLayer: cache.store).contains("alpha body"))
  }

  @Test func theCatalogKeysOfAnEarlierStateFileDoNotNameTheLayer() async throws {
    let fixture = try GitFixtureRepository()
    let head = try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let source = MarketplaceSource(fixture.url)
    let first = try MarketplaceStoreFixture(sources: [source])
    await first.store.start()
    try MarketplaceTestSupport.addEarlierCatalogKeys(
      displayID: Self.earlierDisplayID, catalogVersion: Self.earlierCatalogVersion,
      toStateFile: MarketplaceCache.stateFile(inCacheDirectory: first.cacheDirectory))

    let restarted = try MarketplaceStoreFixture(sources: [source], cacheDirectory: first.cacheDirectory)

    let layer = try #require(restarted.store.marketplaceLayers().first)
    #expect(layer.provenance.id == Self.fixtureID)
    #expect(layer.provenance.displayText == Self.displayText(ofCommit: head))
  }

  // MARK: - Telemetry

  /// A branch that no fixture repository has. A source that follows it fails
  /// at the remote head. The `qz` letters hold no hex digit, thus the text
  /// matches no trace id or span id of a capture by chance.
  private static let missingBranch = "qz-no-such-branch"

  @Test func aPassThatInstallsOpensAPassSpanWithSyncRemoteHeadFetchAndMaterializeChildren() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())

    let (context, _) = try await Telemetry.capture { await cache.store.update() }

    let spans = context.spans
    let pass = try Telemetry.onlySpan(named: MarketplaceTelemetry.SpanName.pass, in: spans)
    Telemetry.expectPass(pass, id: Self.fixtureID, kind: .update, outcome: .updated)
    let sync = try Telemetry.onlyChild(named: MarketplaceTelemetry.SpanName.sync, of: pass, in: spans)
    for name in [
      MarketplaceTelemetry.SpanName.remoteHead, MarketplaceTelemetry.SpanName.fetch,
      MarketplaceTelemetry.SpanName.materialize,
    ] {
      let child = try Telemetry.onlyChild(named: name, of: sync, in: spans)
      Telemetry.expectMarketplaceID(of: child, id: Self.fixtureID)
    }
    Telemetry.expectMarketplaceID(of: sync, id: Self.fixtureID)
    Telemetry.expectNoSpan(named: MarketplaceTelemetry.SpanName.checkHead, in: spans)
    Telemetry.expectEachNameHasThePrefix(in: context)
  }

  @Test func aPassThatInstallsRecordsOneFetchDurationOneHeadDurationAndOneUpdatedCount() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())

    let (context, _) = try await Telemetry.capture { await cache.store.update() }

    let metrics = context.metricsFactory
    Telemetry.expectOneDuration(
      try Telemetry.durations(
        of: MarketplaceTelemetry.MetricName.fetchDuration, in: metrics, id: Self.fixtureID, outcome: .succeeded))
    Telemetry.expectOneDuration(
      try Telemetry.durations(
        of: MarketplaceTelemetry.MetricName.remoteHeadDuration, in: metrics, id: Self.fixtureID,
        outcome: .succeeded))
    #expect(
      try Telemetry.passCounts(in: metrics, id: Self.fixtureID, kind: .update, outcome: .updated)
        == [Int64(Telemetry.one)])
  }

  @Test func aPassThatIsUpToDateReadsTheHeadFetchesNothingAndCountsUpToDate() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())
    await cache.store.start()

    let (context, _) = try await Telemetry.capture { await cache.store.update() }

    let spans = context.spans
    let pass = try Telemetry.onlySpan(named: MarketplaceTelemetry.SpanName.pass, in: spans)
    Telemetry.expectPass(pass, id: Self.fixtureID, kind: .update, outcome: .upToDate)
    let sync = try Telemetry.onlyChild(named: MarketplaceTelemetry.SpanName.sync, of: pass, in: spans)
    _ = try Telemetry.onlyChild(named: MarketplaceTelemetry.SpanName.remoteHead, of: sync, in: spans)
    Telemetry.expectNoSpan(named: MarketplaceTelemetry.SpanName.fetch, in: spans)
    Telemetry.expectNoSpan(named: MarketplaceTelemetry.SpanName.materialize, in: spans)
    let metrics = context.metricsFactory
    Telemetry.expectOneDuration(
      try Telemetry.durations(
        of: MarketplaceTelemetry.MetricName.remoteHeadDuration, in: metrics, id: Self.fixtureID,
        outcome: .succeeded))
    #expect(metrics.timers.filter { $0.label == MarketplaceTelemetry.MetricName.fetchDuration }.isEmpty)
    #expect(
      try Telemetry.passCounts(in: metrics, id: Self.fixtureID, kind: .update, outcome: .upToDate)
        == [Int64(Telemetry.one)])
  }

  @Test func aCheckPassOpensACheckHeadSpanWithARemoteHeadChildAndCountsUpToDate() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())
    await cache.store.start()

    let (context, _) = try await Telemetry.capture { await cache.store.check() }

    let spans = context.spans
    let pass = try Telemetry.onlySpan(named: MarketplaceTelemetry.SpanName.pass, in: spans)
    Telemetry.expectPass(pass, id: Self.fixtureID, kind: .check, outcome: .upToDate)
    let checkHead = try Telemetry.onlyChild(named: MarketplaceTelemetry.SpanName.checkHead, of: pass, in: spans)
    Telemetry.expectMarketplaceID(of: checkHead, id: Self.fixtureID)
    _ = try Telemetry.onlyChild(named: MarketplaceTelemetry.SpanName.remoteHead, of: checkHead, in: spans)
    Telemetry.expectNoSpan(named: MarketplaceTelemetry.SpanName.sync, in: spans)
    #expect(
      try Telemetry.passCounts(in: context.metricsFactory, id: Self.fixtureID, kind: .check, outcome: .upToDate)
        == [Int64(Telemetry.one)])
    Telemetry.expectEachNameHasThePrefix(in: context)
  }

  @Test func aCheckThatFindsANewCommitCountsUpdateAvailable() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())
    await cache.store.start()
    try fixture.commit(files: Self.skillTree(body: "alpha body v2"))

    let (context, _) = try await Telemetry.capture { await cache.store.check() }

    let pass = try Telemetry.onlySpan(named: MarketplaceTelemetry.SpanName.pass, in: context.spans)
    Telemetry.expectPass(pass, id: Self.fixtureID, kind: .check, outcome: .updateAvailable)
    #expect(
      try Telemetry.passCounts(
        in: context.metricsFactory, id: Self.fixtureID, kind: .check, outcome: .updateAvailable)
        == [Int64(Telemetry.one)])
  }

  @Test func aFailedPassMarksThePassTheSyncAndTheRemoteHeadFailedAndCountsFailed() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url, ref: Self.missingBranch)], transport: RecordingGitTransport())

    let (context, events) = try await Telemetry.capture { await cache.store.update() }

    #expect(MarketplaceTestSupport.keptVersion(ofFirst: events) == nil)
    #expect(events.count == Telemetry.one)
    let spans = context.spans
    let pass = try Telemetry.onlySpan(named: MarketplaceTelemetry.SpanName.pass, in: spans)
    Telemetry.expectPass(pass, id: Self.fixtureID, kind: .update, outcome: .failed)
    let sync = try Telemetry.onlyChild(named: MarketplaceTelemetry.SpanName.sync, of: pass, in: spans)
    Telemetry.expectFailure(of: sync)
    Telemetry.expectFailure(
      of: try Telemetry.onlyChild(named: MarketplaceTelemetry.SpanName.remoteHead, of: sync, in: spans))
    let metrics = context.metricsFactory
    Telemetry.expectOneDuration(
      try Telemetry.durations(
        of: MarketplaceTelemetry.MetricName.remoteHeadDuration, in: metrics, id: Self.fixtureID, outcome: .failed))
    #expect(
      try Telemetry.passCounts(in: metrics, id: Self.fixtureID, kind: .update, outcome: .failed)
        == [Int64(Telemetry.one)])
  }

  @Test func noSpanLogRecordOrMetricOfAPassHoldsAURLACredentialAPathARefOrTheErrorText() async throws {
    let good = try GitFixtureRepository()
    try good.commit(files: Self.skillTree(body: "alpha body"))
    let bad = try GitFixtureRepository()
    try bad.commit(files: Self.skillTree(body: "beta body"))
    let cache = try MarketplaceStoreFixture(
      sources: [
        MarketplaceSource(good.url, alias: "good"),
        MarketplaceSource(bad.url, ref: Self.missingBranch, alias: "bad"),
      ],
      policy: MarketplacePolicy(credentials: { _ in Self.credential }), transport: RecordingGitTransport())
    let forbidden = [
      good.url, bad.url, good.directory.path, bad.directory.path, cache.cacheDirectory.path,
      Self.credential.username, Self.credential.token, Self.missingBranch,
    ]

    let (context, events) = try await Telemetry.capture(forbidding: forbidden) { await cache.store.update() }

    let errorTexts = events.compactMap { event -> String? in
      guard case .failed(_, let error, _) = event else { return nil }
      return error
    }
    #expect(errorTexts.count == Telemetry.one)
    #expect(errorTexts.allSatisfy { !$0.isEmpty })
    #expect(context.leaks(forbidding: errorTexts).isEmpty)
  }

  @Test func aPassThatInstallsANewSnapshotRecordsOneInstallDuration() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())

    let (context, _) = try await Telemetry.capture { await cache.store.update() }

    Telemetry.expectOneDuration(
      try Telemetry.installDurations(in: context.metricsFactory, id: Self.fixtureID, outcome: .succeeded))
  }

  @Test func noSpanLogRecordOrMetricOfTheCacheHoldsTheCachePathOrTheLockFilePath() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let source = MarketplaceSource(fixture.url)
    let cache = try MarketplaceStoreFixture(sources: [source], transport: RecordingGitTransport())
    let marketplaceCache = try MarketplaceTestSupport.cache(of: source, inCacheDirectory: cache.cacheDirectory)
    let forbidden = [cache.cacheDirectory.path, marketplaceCache.lockFile.path]

    let (context, refused) = try await Telemetry.capture(forbidding: forbidden) {
      await cache.store.update()
      // A second writer holds the lock, thus the forced pass meets the
      // writer lock and fails with the path of the lock file in its text.
      return try? await marketplaceCache.withWriterLock { await cache.store.update(force: true) }
    }

    #expect(refused?.count == Telemetry.one)
    #expect(
      try Telemetry.cacheCounts(
        of: MarketplaceTelemetry.MetricName.writerLockConflicts, in: context.metricsFactory, id: Self.fixtureID)
        == [Int64(Telemetry.one)])
  }

  @Test func aStoreOverACacheThatHoldsASnapshotCountsOneServeOfTheCurrentSnapshot() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let first = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])
    await first.store.start()

    let (context, restarted) = try await Telemetry.capture {
      try? MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)], cacheDirectory: first.cacheDirectory)
    }

    #expect(restarted != nil)
    #expect(
      Telemetry.servedCounts(in: context.metricsFactory, id: Self.fixtureID) == [.current: [Int64(Telemetry.one)]])
  }

  @Test func aStoreThatTheSeedFolderServesCountsOneServeOfTheSeedSnapshot() async throws {
    let seed = try await SeedFixture.make()

    let (context, store) = try await Telemetry.capture { try? seed.makeStore() }

    #expect(store != nil)
    #expect(
      Telemetry.servedCounts(in: context.metricsFactory, id: Self.fixtureID) == [.seed: [Int64(Telemetry.one)]])
  }

  @Test func aPassThatInstallsANewSnapshotCountsOneServeOfTheInstalledSnapshot() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())

    let (context, _) = try await Telemetry.capture { await cache.store.update() }

    #expect(
      Telemetry.servedCounts(in: context.metricsFactory, id: Self.fixtureID) == [.installed: [Int64(Telemetry.one)]])
  }

  @Test func noSpanLogRecordOrMetricOfAServedSnapshotHoldsTheCachePathOrTheSeedPath() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: Self.skillTree(body: "alpha body"))
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], transport: RecordingGitTransport())
    let seed = try await SeedFixture.make()
    let forbidden = [
      cache.cacheDirectory.path, seed.seedDirectory.path, fixture.directory.path, seed.repository.directory.path,
    ]

    let (context, _) = try await Telemetry.capture(forbidding: forbidden) {
      await cache.store.update()
      _ = try? MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)], cacheDirectory: cache.cacheDirectory)
      _ = try? seed.makeStore()
    }

    let one = [Int64(Telemetry.one)]
    #expect(
      Telemetry.servedCounts(in: context.metricsFactory, id: Self.fixtureID)
        == [.installed: one, .current: one, .seed: one])
  }

  // MARK: - Support

  /// The helpers that read the telemetry of a store test.
  private typealias Telemetry = MarketplaceTelemetryExpectations

  /// The display text of the fixture marketplace at one commit: the
  /// pre-fetch key and the short commit.
  ///
  /// - Parameter commit: The commit of the snapshot.
  /// - Returns: The text, for example `fixture@1a2b3c4`.
  private static func displayText(ofCommit commit: String) -> String {
    "\(fixtureID)@\(commit.prefix(shortShaLength))"
  }

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

  /// The name of the agent of ``agentTree(body:)``.
  private static let agentName = "reviewer"

  /// The path of the agent document of ``agentTree(body:)``, relative to the
  /// agents folder.
  private static let agentDocumentPath = "\(agentName)/\(MarketplaceLayer.agentDocumentName)"

  /// The partial of ``agentTree(body:)``, relative to the layer root.
  private static let partialPath = "\(MarketplaceLayout.defaultPartialsDirectoryName)/sah-rules.md"

  /// The text of the partial of ``agentTree(body:)``.
  private static let partialText = "Fixture rules."

  /// The tree of a fixture in the shape of the `swissarmyhammer/skills`
  /// marketplace, with no catalog file: one skill, one partial beside the
  /// skill, and one agent folder in `agents/`.
  ///
  /// - Parameter body: The body of the skill.
  /// - Returns: The tree, one entry for each path.
  private static func agentTree(body: String) -> [String: GitFixtureRepository.Entry] {
    skillTree(body: body).merging([
      "\(MarketplaceTestSupport.skillsFolderName)/\(partialPath)": .file(partialText),
      "\(MarketplaceLayer.agentsDirectoryName)/\(agentDocumentPath)":
        .file(MarketplaceTestSupport.agentDocument(named: agentName)),
    ]) { _, later in later }
  }
}
