import Foundation
import MarketplaceFixtures
import Testing

@testable import Marketplace

/// Tests for the update checks and the automatic update of
/// ``MarketplaceStore`` (marketplace.md §8.1 to §8.3, decisions 13 and 15).
///
/// The package holds no time value of its own. Thus no test here waits for
/// real time: the store gets a ``ManualClock``, and each assertion follows an
/// event of the store or a count of the ``GitTransport`` double.
@Suite("Marketplace update")
struct MarketplaceUpdateTests {
  /// The interval that a host gives the periodic check. The value belongs to
  /// the test: the manual clock advances by it, thus the test waits for no
  /// real time.
  private static let hostInterval: Duration = .seconds(30)

  /// The fetch timeout that a host gives. The value belongs to the test, as
  /// ``hostInterval`` does.
  private static let hostFetchTimeout: Duration = .seconds(5)

  /// The display id of a fixture marketplace, which is its repository name.
  private static let fixtureID = "fixture"

  /// How many remote-head calls a checking store made after ``start()`` and
  /// one step of the clock.
  private static let callsAfterOneStep = 2

  /// How many remote-head calls a checking store made after ``start()`` and
  /// two steps of the clock.
  private static let callsAfterTwoSteps = 3

  /// How many fetches a store made when the blocked update entered the
  /// transport: the one of ``start()``, and the blocked one.
  private static let fetchesAtTheBlockedUpdate = 2

  // MARK: - No built-in time

  @Test func theDefaultPolicyChecksOneTimeForEachSourceAndThenWaitsForARequest() async throws {
    let cache = try Self.makeCheckingStore(policy: MarketplacePolicy())

    await cache.store.start()
    cache.clock.advance(by: Self.hostInterval)

    #expect(await cache.transport.remoteHeadCount == 1)
    #expect(await cache.transport.fetchCount == 1)
    #expect(cache.clock.sleepCount == 0)
  }

  @Test func twoConcurrentChecksMakeOneRemoteHeadCall() async throws {
    let cache = try Self.makeCheckingStore(policy: MarketplacePolicy(), remoteHead: .holdThenPass)
    let secondIsRunning = TestSignal()
    let store = cache.store

    let first = Task { await store.check() }
    await cache.gate.waitForEntry(of: .remoteHead)
    let second = Task { () -> [MarketplaceStatus] in
      await secondIsRunning.signal()
      return await store.check()
    }
    await secondIsRunning.wait()
    await cache.gate.release()
    let firstStatuses = await first.value
    let secondStatuses = await second.value

    #expect(await cache.transport.remoteHeadCount == 1)
    #expect(firstStatuses == secondStatuses)
  }

  // MARK: - Update rules

  @Test func theDefaultPolicyInstallsTheHeadAtStart() async throws {
    let cache = try Self.makeCheckingStore(policy: MarketplacePolicy())

    await cache.store.start()

    #expect(cache.store.marketplaceLayers().first?.provenance.sha == cache.head)
  }

  @Test func autoUpdateOffPublishesUpdateAvailableAndNeverFetches() async throws {
    let cache = try Self.makeCheckingStore(policy: MarketplacePolicy(autoUpdate: false))

    await cache.store.start()

    #expect(await cache.transport.fetchCount == 0)
    #expect(await cache.transport.remoteHeadCount == 1)
    #expect(await cache.log.waitForEvent(where: Self.isUpdateAvailable) == cache.expectedEvent)
  }

  @Test func theEnvironmentSwitchStopsTheAutomaticUpdate() async throws {
    let policy = MarketplacePolicy(environment: [MarketplacePolicy.automaticUpdateVariable: "0"])
    let cache = try Self.makeCheckingStore(policy: policy)

    await cache.store.start()

    #expect(await cache.transport.fetchCount == 0)
    #expect(await cache.log.waitForEvent(where: Self.isUpdateAvailable) == cache.expectedEvent)
  }

  @Test func checkOnlyNeverFetchesEvenWhenTheHostAsksForAnUpdate() async throws {
    let cache = try Self.makeCheckingStore(policy: MarketplacePolicy(checkOnly: true))

    await cache.store.start()
    let events = await cache.store.update()

    #expect(events == [cache.expectedEvent])
    #expect(await cache.transport.fetchCount == 0)
  }

  @Test func aCheckReportsTheHeadThatTheSnapshotDoesNotHold() async throws {
    let cache = try Self.makeCheckingStore(policy: MarketplacePolicy(autoUpdate: false))

    let statuses = await cache.store.check()

    #expect(statuses.count == 1)
    #expect(statuses.first?.id == Self.fixtureID)
    #expect(statuses.first?.current == nil)
    #expect(statuses.first?.latest == cache.head)
    #expect(statuses.first?.updateAvailable == true)
    #expect(await cache.transport.fetchCount == 0)
  }

  // MARK: - The optional interval loop

  @Test func theIntervalLoopChecksOneTimeForEachStepOfTheClock() async throws {
    let cache = try Self.makeCheckingStore(
      policy: MarketplacePolicy(checkInterval: Self.hostInterval, autoUpdate: false))

    await cache.store.start()
    await cache.clock.waitForSleeper()
    cache.clock.advance(by: Self.hostInterval)
    await cache.gate.waitForEntry(of: .remoteHead, count: Self.callsAfterOneStep)
    await cache.clock.waitForSleeper()
    cache.clock.advance(by: Self.hostInterval)
    await cache.gate.waitForEntry(of: .remoteHead, count: Self.callsAfterTwoSteps)

    #expect(await cache.transport.remoteHeadCount == Self.callsAfterTwoSteps)
  }

  @Test func stopEndsTheIntervalLoop() async throws {
    let cache = try Self.makeCheckingStore(
      policy: MarketplacePolicy(checkInterval: Self.hostInterval, autoUpdate: false))

    await cache.store.start()
    await cache.clock.waitForSleeper()
    await cache.store.stop()
    await cache.clock.waitForNoSleeper()
    cache.clock.advance(by: Self.hostInterval)

    #expect(await cache.gate.entryCount(of: .remoteHead) == 1)
  }

  // MARK: - Cancellation and the fetch timeout

  @Test func stopDuringAFetchKeepsTheSnapshotThatCurrentNames() async throws {
    let cache = try await Self.makeStoreWithABlockedUpdate(policy: MarketplacePolicy())
    let store = cache.store

    let updating = Task { await store.update() }
    await cache.gate.waitForEntry(of: .fetch, count: Self.fetchesAtTheBlockedUpdate)
    await cache.store.stop()
    let events = await updating.value

    #expect(MarketplaceTestSupport.keptVersion(ofFirst: events) == cache.head)
    #expect(cache.store.marketplaceLayers().first?.provenance.sha == cache.head)
  }

  @Test func aFetchLongerThanTheTimeoutFailsAndKeepsTheSnapshot() async throws {
    let cache = try await Self.makeStoreWithABlockedUpdate(
      policy: MarketplacePolicy(fetchTimeout: Self.hostFetchTimeout))
    let store = cache.store

    let updating = Task { await store.update() }
    await cache.gate.waitForEntry(of: .fetch, count: Self.fetchesAtTheBlockedUpdate)
    await cache.clock.waitForSleeper()
    cache.clock.advance(by: Self.hostFetchTimeout)
    let events = await updating.value

    #expect(MarketplaceTestSupport.keptVersion(ofFirst: events) == cache.head)
    #expect(cache.store.marketplaceLayers().first?.provenance.sha == cache.head)
  }

  // MARK: - Fixtures

  /// One store over a fixture repository, with everything that a test of
  /// this suite reads.
  ///
  /// The type is a class, thus it cancels the task that follows the events
  /// when the test is over.
  private final class CheckingStore {
    /// The repository that the marketplace source names.
    let repository: GitFixtureRepository

    /// The store and its temporary cache.
    let cache: MarketplaceStoreFixture

    /// The counting transport under the gate.
    let transport: RecordingGitTransport

    /// The gate, which counts each call that enters it and holds the call
    /// that the test needs to hold.
    let gate: GatedGitTransport

    /// The clock of the store.
    let clock: ManualClock

    /// The events of the store, from before the first call.
    let log: MarketplaceEventLog

    /// The task that fills ``log``.
    let subscription: Task<Void, Never>

    /// The first commit of the repository. A store that ran `start()`
    /// holds it as the snapshot that `current` names.
    let head: String

    /// The store under test.
    var store: MarketplaceStore {
      cache.store
    }

    /// The event that a store with no automatic update publishes for the
    /// fixture.
    var expectedEvent: MarketplaceEvent {
      .updateAvailable(id: MarketplaceUpdateTests.fixtureID, from: nil, to: head)
    }

    /// Makes the fixture over a repository with one commit.
    ///
    /// - Parameters:
    ///   - policy: The policy of the store.
    ///   - remoteHead: What the gate does with a remote-head call.
    /// - Throws: The error of a fixture step.
    init(policy: MarketplacePolicy, remoteHead: GatedGitTransport.Behavior) throws {
      repository = try GitFixtureRepository()
      head = try repository.commit(files: MarketplaceTestSupport.skillTree(body: "alpha body"))
      transport = RecordingGitTransport()
      gate = GatedGitTransport(wrapping: transport, remoteHead: remoteHead)
      clock = ManualClock()
      cache = try MarketplaceStoreFixture(
        sources: [MarketplaceSource(repository.url)], policy: policy, transport: gate, clock: clock)
      log = MarketplaceEventLog()
      subscription = log.follow(cache.store.events)
    }

    deinit {
      subscription.cancel()
    }
  }

  /// Makes a store over a fixture repository with one commit, and follows
  /// its events from before the first call.
  ///
  /// - Parameters:
  ///   - policy: The policy of the store. The caller sets the fields that
  ///     its test needs.
  ///   - remoteHead: What the gate does with a remote-head call. The default
  ///     is ``GatedGitTransport/Behavior/pass``.
  /// - Returns: The store and what the test reads.
  /// - Throws: The error of a fixture step.
  private static func makeCheckingStore(
    policy: MarketplacePolicy, remoteHead: GatedGitTransport.Behavior = .pass
  ) throws -> CheckingStore {
    try CheckingStore(policy: policy, remoteHead: remoteHead)
  }

  /// Makes a store that installed the head of its fixture and whose next
  /// fetch is held until its task is cancelled.
  ///
  /// The repository then gets a second commit, thus the update of the test
  /// reaches the fetch that the gate holds.
  ///
  /// - Parameter policy: The policy of the store.
  /// - Returns: The store and what the test reads.
  /// - Throws: The error of a fixture step.
  private static func makeStoreWithABlockedUpdate(policy: MarketplacePolicy) async throws -> CheckingStore {
    let cache = try makeCheckingStore(policy: policy)
    await cache.store.start()
    await cache.gate.setBehavior(.holdUntilCancelled, of: .fetch)
    try cache.repository.commit(files: MarketplaceTestSupport.skillTree(body: "alpha body v2"))
    return cache
  }

  /// Whether one event says that the remote holds a commit that the
  /// snapshot does not.
  private static let isUpdateAvailable: @Sendable (MarketplaceEvent) -> Bool = { event in
    if case .updateAvailable = event {
      return true
    }
    return false
  }
}
