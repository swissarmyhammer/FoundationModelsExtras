import FixtureSupport
import Foundation
import MarketplaceFixtures
import Testing

@testable import Marketplace

/// Tests for the pins of ``MarketplaceStore`` and for
/// ``MarketplacePolicy/ApplyUpdates/nextLaunch`` (marketplace.md §8.3 and
/// §8.4).
///
/// The package holds no time value of its own. A pending snapshot is a flag
/// in `state.json` that the next ``MarketplaceStore/start()`` reads, thus no
/// test here waits for real time: each assertion follows a call of the store
/// or a record on the disk.
@Suite("Marketplace pin")
struct MarketplacePinTests {
  /// The display id of a fixture marketplace, which is its repository name.
  private static let fixtureID = "fixture"

  /// The body of the first commit of a fixture repository.
  private static let firstBody = "alpha body"

  /// The body of the second commit, which the remote head names when the
  /// fixture is made.
  private static let headBody = "alpha body v2"

  /// The body of a commit that a test adds after the store started.
  private static let laterBody = "alpha body v3"

  /// The body of a commit that a test adds after a snapshot waits for the
  /// next launch.
  private static let newestBody = "alpha body v4"

  /// How many fetches a store made when the held pass entered the gate: the
  /// one of the first `start()`, the one of the `update()` that staged a
  /// pending snapshot, and the held one.
  private static let fetchesAtTheHeldPass = 3

  /// The words of ``MarketplaceCacheError/writerLockHeld(path:)`` that the
  /// text of a failure event carries.
  private static let writerLockRefusal = "Another writer holds the marketplace folder"

  /// The id that no marketplace of a fixture has.
  private static let unknownID = "no-such-marketplace"

  /// A commit that no fixture repository holds. It is a hexadecimal object
  /// name, thus only the kind of the marketplace can refuse the pin.
  private static let wellFormedCommit = "0123456789abcdef0123456789abcdef01234567"

  /// A pin that is no commit at all.
  private static let malformedCommit = "not-a-commit"

  // MARK: - The pin of a source (§8.3)

  @Test func theShaFieldOfASourceInstallsThatCommitAndNotTheHead() async throws {
    let pinned = try PinFixture(pinToFirstCommit: true)

    await pinned.store.start()

    #expect(pinned.store.marketplaceLayers().first?.provenance.sha == pinned.first)
  }

  @Test func aCheckOfAPinnedSourceReportsTheNewerHead() async throws {
    let pinned = try PinFixture(pinToFirstCommit: true)
    await pinned.store.start()

    let statuses = await pinned.store.check()

    #expect(statuses.first?.current == pinned.first)
    #expect(statuses.first?.latest == pinned.head)
    #expect(statuses.first?.updateAvailable == true)
  }

  // MARK: - pin and unpin (§8.3)

  @Test func pinStopsTheNextUpdateAtTheNamedCommit() async throws {
    let fixture = try PinFixture()
    await fixture.store.start()
    try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.laterBody))

    try await fixture.store.pin(Self.fixtureID, sha: fixture.head)
    await fixture.store.update()

    #expect(fixture.store.marketplaceLayers().first?.provenance.sha == fixture.head)
  }

  @Test func pinWritesTheCommitIntoTheStateFile() async throws {
    let fixture = try PinFixture()
    await fixture.store.start()

    try await fixture.store.pin(Self.fixtureID, sha: fixture.first)

    #expect(try Self.record(inCacheOf: fixture)?.pinnedSha == fixture.first)
  }

  @Test func unpinLetsTheNextUpdateFetchTheHead() async throws {
    let pinned = try PinFixture(pinToFirstCommit: true)
    await pinned.store.start()

    try await pinned.store.unpin(Self.fixtureID)
    await pinned.store.update()

    #expect(pinned.store.marketplaceLayers().first?.provenance.sha == pinned.head)
  }

  @Test func unpinClearsTheCommitInTheStateFile() async throws {
    let fixture = try PinFixture()
    await fixture.store.start()
    try await fixture.store.pin(Self.fixtureID, sha: fixture.first)

    try await fixture.store.unpin(Self.fixtureID)

    let record = try Self.record(inCacheOf: fixture)
    #expect(record?.pinnedSha == nil)
    #expect(record?.unpinned == true)
  }

  @Test func aForcedUpdateOfAPinnedSourceKeepsThePinnedCommit() async throws {
    let pinned = try PinFixture(pinToFirstCommit: true)
    await pinned.store.start()

    await pinned.store.update(Self.fixtureID, force: true)

    #expect(pinned.store.marketplaceLayers().first?.provenance.sha == pinned.first)
  }

  @Test func pinOfAnUnknownMarketplaceThrows() async throws {
    let fixture = try PinFixture()

    await #expect(throws: MarketplacePinError.unknownMarketplace(id: Self.unknownID)) {
      try await fixture.store.pin(Self.unknownID, sha: fixture.first)
    }
  }

  @Test func unpinOfAnUnknownMarketplaceThrows() async throws {
    let fixture = try PinFixture()

    await #expect(throws: MarketplacePinError.unknownMarketplace(id: Self.unknownID)) {
      try await fixture.store.unpin(Self.unknownID)
    }
  }

  @Test func aPinThatIsNoCommitThrows() async throws {
    let fixture = try PinFixture()

    await #expect(throws: MarketplaceCacheError.notACommit(value: Self.malformedCommit)) {
      try await fixture.store.pin(Self.fixtureID, sha: Self.malformedCommit)
    }
  }

  @Test func pinOfAFolderOnThisComputerThrows() async throws {
    let folder = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try MarketplaceStoreFixture(sources: [MarketplaceSource("file://\(folder.path)")])
    let id = try #require(store.store.marketplaceLayers().first?.provenance.id)

    await #expect(throws: MarketplacePinError.notAGitMarketplace(id: id)) {
      try await store.store.pin(id, sha: Self.wellFormedCommit)
    }
  }

  // MARK: - .nextLaunch (§8.4)

  @Test func nextLaunchLeavesTheServedSnapshotWhereItIs() async throws {
    let fixture = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch))
    await fixture.store.start()
    try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.laterBody))

    await fixture.store.update()

    #expect(fixture.store.marketplaceLayers().first?.provenance.sha == fixture.head)
  }

  @Test func nextLaunchReportsTheStagedSnapshotAsAvailable() async throws {
    let fixture = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch))
    await fixture.store.start()
    let later = try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.laterBody))

    let events = await fixture.store.update()

    #expect(events == [.updateAvailable(id: Self.fixtureID, from: fixture.head, to: later)])
  }

  @Test func nextLaunchWritesThePendingSnapshotIntoTheStateFile() async throws {
    let fixture = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch))
    await fixture.store.start()
    let later = try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.laterBody))

    await fixture.store.update()

    let record = try Self.record(inCacheOf: fixture)
    #expect(record?.pending?.sha == later)
    #expect(record?.currentSha == fixture.head)
  }

  @Test func nextLaunchSwapsTheSnapshotAtTheNextStart() async throws {
    let fixture = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch))
    await fixture.store.start()
    let later = try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.laterBody))
    await fixture.store.update()

    await fixture.store.start()

    #expect(fixture.store.marketplaceLayers().first?.provenance.sha == later)
    #expect(try Self.record(inCacheOf: fixture)?.pending == nil)
  }

  @Test func aPendingSnapshotSurvivesANewStoreOverTheSameCache() async throws {
    let fixture = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch))
    await fixture.store.start()
    let later = try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.laterBody))
    await fixture.store.update()
    let restarted = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch), sharing: fixture)

    await restarted.store.start()

    #expect(restarted.store.marketplaceLayers().first?.provenance.sha == later)
  }

  // MARK: - A staged snapshot that another process deleted (§8.4)

  @Test func adoptRefusesAStagedSnapshotThatAnotherProcessDeleted() async throws {
    let pruned = try await Self.makePrunedStagedFixture()

    #expect(throws: MarketplaceCacheError.snapshotMissing(sha: pruned.staged)) {
      try pruned.cache.adopt(snapshotSha: pruned.staged, ref: nil)
    }
  }

  @Test func adoptKeepsTheServedSnapshotWhenTheStagedOneIsGone() async throws {
    let pruned = try await Self.makePrunedStagedFixture()

    #expect(throws: MarketplaceCacheError.snapshotMissing(sha: pruned.staged)) {
      try pruned.cache.adopt(snapshotSha: pruned.staged, ref: nil)
    }

    #expect(pruned.cache.currentSha() == pruned.fixture.head)
    let served = try #require(pruned.cache.currentSnapshot())
    #expect(FileManager.default.fileExists(atPath: served.path))
  }

  @Test func aStartAfterAStagedSnapshotIsDeletedKeepsTheServedSnapshot() async throws {
    let pruned = try await Self.makePrunedStagedFixture()
    let restarted = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch), sharing: pruned.fixture)

    await restarted.store.start()

    #expect(restarted.store.marketplaceLayers().first?.provenance.sha == pruned.fixture.head)
  }

  // MARK: - Two passes over one writer lock (§7.6)

  @Test func aSecondStartFinishesWhileAPassHoldsTheWriterLock() async throws {
    let gate = GatedGitTransport(wrapping: LibGit2Transport())
    let fixture = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch), transport: gate)
    let log = MarketplaceEventLog()
    let subscription = log.follow(fixture.store.events)
    defer { subscription.cancel() }
    await fixture.store.start()
    let staged = try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.laterBody))
    await fixture.store.update()
    await gate.setBehavior(.holdThenPass, of: .fetch)
    try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: Self.newestBody))

    let store = fixture.store
    let held = Task { await store.start() }
    await gate.waitForEntry(of: .fetch, count: Self.fetchesAtTheHeldPass)
    try Self.stagePending(sha: fixture.head, inCacheOf: fixture)
    let second = Task { await store.start() }
    let refusal = await log.waitForEvent { Self.namesTheWriterLock($0) }
    await gate.release()
    await held.value
    await second.value

    #expect(Self.namesTheWriterLock(refusal))
    #expect(fixture.store.marketplaceLayers().first?.provenance.sha == staged)
  }

  // MARK: - Fixtures

  /// One fixture repository with two commits, and a store over a temporary
  /// cache.
  ///
  /// The type is a class, thus the repository and the cache live as long as
  /// the test that holds them.
  private final class PinFixture {
    /// The repository that the marketplace source names.
    let repository: GitFixtureRepository

    /// The first commit of the repository.
    let first: String

    /// The second commit, which the remote head named when the fixture
    /// was made.
    let head: String

    /// The store and its cache.
    let cache: MarketplaceStoreFixture

    /// The store under test.
    var store: MarketplaceStore {
      cache.store
    }

    /// Makes a repository with two commits, and a store over it.
    ///
    /// - Parameters:
    ///   - pinToFirstCommit: Whether the `sha` field of the source names
    ///     the first commit, which the remote head no longer names. The
    ///     default is `false`.
    ///   - policy: The policy of the store. The default is
    ///     `MarketplacePolicy()`.
    ///   - transport: The git transport, or `nil` for the real one. The
    ///     default is `nil`.
    /// - Throws: The error of a fixture step.
    init(
      pinToFirstCommit: Bool = false, policy: MarketplacePolicy = MarketplacePolicy(),
      transport: (any GitTransport)? = nil
    ) throws {
      repository = try GitFixtureRepository()
      first = try repository.commit(files: MarketplaceTestSupport.skillTree(body: MarketplacePinTests.firstBody))
      head = try repository.commit(files: MarketplaceTestSupport.skillTree(body: MarketplacePinTests.headBody))
      cache = try MarketplaceStoreFixture(
        sources: [MarketplaceSource(repository.url, sha: pinToFirstCommit ? first : nil)],
        policy: policy, transport: transport)
    }

    /// Makes a second store over the repository and the cache of another
    /// fixture, as a new process would.
    ///
    /// - Parameters:
    ///   - policy: The policy of the store. The default is
    ///     `MarketplacePolicy()`.
    ///   - other: The fixture that owns the repository and the cache.
    /// - Throws: The error of a fixture step.
    init(policy: MarketplacePolicy = MarketplacePolicy(), sharing other: PinFixture) throws {
      repository = other.repository
      first = other.first
      head = other.head
      cache = try MarketplaceStoreFixture(
        sources: [MarketplaceSource(other.repository.url)], cacheDirectory: other.cache.cacheDirectory,
        policy: policy)
    }
  }

  /// A fixture whose cache holds a staged snapshot that no launch served
  /// yet, and whose staged folder another process then deleted.
  ///
  /// The delete stands for a pruner in a second process: it removes a
  /// snapshot that no reader holds, thus a staged snapshot can be gone
  /// before a later launch serves it.
  ///
  /// - Returns: The fixture, the cache of its one marketplace, and the
  ///   commit of the snapshot that is gone.
  /// - Throws: The error of a fixture step or of the delete.
  private static func makePrunedStagedFixture() async throws -> (
    fixture: PinFixture, cache: MarketplaceCache, staged: String
  ) {
    let fixture = try PinFixture(policy: MarketplacePolicy(applyUpdates: .nextLaunch))
    await fixture.store.start()
    let staged = try fixture.repository.commit(files: MarketplaceTestSupport.skillTree(body: laterBody))
    await fixture.store.update()
    let cache = try Self.cache(inCacheOf: fixture)
    try FileManager.default.removeItem(at: cache.snapshotDirectory(forSha: staged))
    return (fixture, cache, staged)
  }

  /// The cache of the one marketplace of a fixture.
  ///
  /// - Parameter fixture: The fixture whose cache holds `state.json`.
  /// - Returns: The cache, over the folder that the state file names.
  /// - Throws: The error of the file read, or a failed requirement when the
  ///   state file names no marketplace.
  private static func cache(inCacheOf fixture: PinFixture) throws -> MarketplaceCache {
    let directory = fixture.cache.cacheDirectory
    let state = try MarketplaceState.load(from: MarketplaceCache.stateFile(inCacheDirectory: directory))
    let folderName = try #require(state.marketplaces.keys.first)
    return MarketplaceCache(root: directory, folderName: folderName)
  }

  /// Writes a pending snapshot into the state file of a fixture, as a
  /// second process over the same cache would (marketplace.md §8.4).
  ///
  /// - Parameters:
  ///   - sha: The commit of a snapshot that the cache already holds.
  ///   - fixture: The fixture whose cache holds `state.json`.
  /// - Throws: The error of the file read or of the file write, or a failed
  ///   requirement when the state file names no marketplace.
  private static func stagePending(sha: String, inCacheOf fixture: PinFixture) throws {
    let file = MarketplaceCache.stateFile(inCacheDirectory: fixture.cache.cacheDirectory)
    var state = try MarketplaceState.load(from: file)
    let folderName = try #require(state.marketplaces.keys.first)
    state.marketplaces[folderName]?.pending = MarketplacePendingSnapshot(sha: sha)
    try state.save(to: file)
  }

  /// Whether one event says that another writer holds the marketplace
  /// folder.
  ///
  /// - Parameter event: The event to read.
  /// - Returns: `true` for the failure of a call that met the writer lock.
  private static func namesTheWriterLock(_ event: MarketplaceEvent) -> Bool {
    if case .failed(_, let error, _) = event {
      return error.contains(writerLockRefusal)
    }
    return false
  }

  /// The one state record of the cache of a fixture.
  ///
  /// - Parameter fixture: The fixture whose cache holds `state.json`.
  /// - Returns: The record, or `nil` when the file holds none.
  /// - Throws: The error of the file read or of the JSON decoder.
  private static func record(inCacheOf fixture: PinFixture) throws -> MarketplaceStateRecord? {
    let file = MarketplaceCache.stateFile(inCacheDirectory: fixture.cache.cacheDirectory)
    return try MarketplaceState.load(from: file).marketplaces.values.first
  }
}
