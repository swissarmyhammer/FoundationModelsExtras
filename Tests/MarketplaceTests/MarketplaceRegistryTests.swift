import Testing

@testable import Marketplace

/// Proves ``MarketplaceRegistry`` over ``InMemoryMarketplaceSourceStorage``:
/// each operation reads the stored list, validates it, changes it, saves it,
/// and then sends one change.
///
/// Every test is pure: no test reads the disk or the network.
@Suite("Marketplace registry")
struct MarketplaceRegistryTests {
  /// A marketplace with the pre-fetch key `team-skills`.
  private static let teamSkills = MarketplaceSource("github:acme/team-skills")

  /// A marketplace with the pre-fetch key `skills`.
  private static let skills = MarketplaceSource("https://github.com/swissarmyhammer/skills.git")

  /// A marketplace on another host with the same pre-fetch key as
  /// ``teamSkills``.
  private static let otherTeamSkills = MarketplaceSource("https://example.com/acme/team-skills.git")

  /// A source whose URL is of no supported form.
  private static let badURL = MarketplaceSource("ftp://example.com/skills.git")

  /// An alias that is not one folder name.
  private static let unusableAlias = "team/skills"

  /// ``skills`` at a branch: the same id, another source.
  private static let skillsOnBranch = MarketplaceSource(skills.url, ref: "next")

  /// ``skills`` under a new alias.
  private static let renamedSkills = MarketplaceSource(skills.url, alias: "renamed")

  /// The id of ``renamedSkills``.
  private static let renamedSkillsID = "renamed"

  /// The id of ``teamSkills``.
  private static let teamSkillsID = "team-skills"

  /// The id of ``skills``.
  private static let skillsID = "skills"

  /// An id that no source of the tests has.
  private static let unknownID = "nothing"

  /// How many adds the concurrency test runs at the same time.
  private static let concurrentAddCount = 16

  /// A marketplace with the pre-fetch key `docs`.
  private static let docs = MarketplaceSource("github:acme/docs")

  /// The id of ``docs``.
  private static let docsID = "docs"

  /// A marketplace with the pre-fetch key `tools`.
  private static let tools = MarketplaceSource("github:acme/tools")

  /// A marketplace with the pre-fetch key `prompts`.
  private static let prompts = MarketplaceSource("github:acme/prompts")

  /// The marketplace that a test adds after the operation that it examines.
  /// Its change marks the end of the changes of that operation.
  private static let marker = MarketplaceSource("github:acme/marker")

  /// How long the queue test waits for its add to reach the registry, while
  /// the reset waits in the storage.
  private static let addArrivalTime: Duration = .milliseconds(50)

  /// Makes the entry of a source that the tests know is valid.
  ///
  /// - Parameter source: The source.
  /// - Returns: The entry.
  private static func entry(_ source: MarketplaceSource) throws -> MarketplaceEntry {
    try MarketplaceEntry(source: source)
  }

  /// Makes a registry over an in-memory storage that holds `sources`.
  ///
  /// - Parameters:
  ///   - sources: The list that the storage holds at the start.
  ///   - defaultSources: The list that a reset of the storage stores.
  /// - Returns: The registry and its storage.
  private static func makeRegistry(
    _ sources: [MarketplaceSource] = [],
    defaultSources: [MarketplaceSource] = []
  ) -> (registry: MarketplaceRegistry, storage: InMemoryMarketplaceSourceStorage) {
    let storage = InMemoryMarketplaceSourceStorage(sources: sources, defaultSources: defaultSources)
    return (MarketplaceRegistry(storage: storage), storage)
  }

  /// Gives each change that the registry sends during `operation`.
  ///
  /// After `operation`, the function adds ``marker``, and it reads the
  /// changes until the change of that add. Thus an operation that sends no
  /// change gives an empty list, and the function does not wait forever.
  ///
  /// - Parameters:
  ///   - registry: The registry. The stored list must accept ``marker``
  ///     after `operation`.
  ///   - operation: The operation to examine.
  /// - Returns: The changes of `operation`, in the order that the registry
  ///   sent them.
  private static func changes(
    of registry: MarketplaceRegistry,
    during operation: () async throws -> Void
  ) async throws -> [MarketplaceRegistryChange] {
    var iterator = registry.changes().makeAsyncIterator()
    try await operation()
    let markerChange = MarketplaceRegistryChange.added(try await registry.add(marker))
    var changes: [MarketplaceRegistryChange] = []
    while let change = await iterator.next(), change != markerChange {
      changes.append(change)
    }
    return changes
  }

  // MARK: - Storage

  @Test func theInMemoryStorageGivesBackTheListThatItSaved() async throws {
    let storage: any MarketplaceSourceStorage = InMemoryMarketplaceSourceStorage()

    try await storage.saveSources([Self.teamSkills, Self.skills])

    #expect(try await storage.loadSources() == [Self.teamSkills, Self.skills])
  }

  @Test func theDefaultResetOfAStorageGivesAnEmptyList() async throws {
    let storage = FailingMarketplaceSourceStorage(failing: nil, sources: [Self.teamSkills])

    #expect(try await storage.resetSources() == [])
  }

  @Test func theDefaultResetOfAStorageSavesAnEmptyList() async throws {
    let storage = FailingMarketplaceSourceStorage(failing: nil, sources: [Self.teamSkills])

    _ = try await storage.resetSources()

    #expect(await storage.sources == [])
  }

  @Test func theInMemoryResetGivesTheDefaultList() async throws {
    let storage = InMemoryMarketplaceSourceStorage(sources: [Self.teamSkills], defaultSources: [Self.skills])

    #expect(await storage.resetSources() == [Self.skills])
  }

  @Test func theInMemoryResetStoresTheDefaultList() async throws {
    let storage = InMemoryMarketplaceSourceStorage(sources: [Self.teamSkills], defaultSources: [Self.skills])

    _ = await storage.resetSources()

    #expect(await storage.loadSources() == [Self.skills])
  }

  @Test func theInMemoryDefaultListIsEmptyWhenTheInitGetsNone() async throws {
    let storage = InMemoryMarketplaceSourceStorage(sources: [Self.teamSkills])

    #expect(await storage.resetSources() == [])
  }

  // MARK: - Read

  @Test func theListGivesOneEntryForEachStoredSourceInListOrder() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills, Self.skills])

    let ids = try await registry.marketplaces().map(\.id)

    #expect(ids == [Self.teamSkillsID, Self.skillsID])
  }

  @Test func oneMarketplaceIsFoundByItsID() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills, Self.skills])

    let entry = try await registry.marketplace(id: Self.skillsID)

    #expect(entry?.source == Self.skills)
  }

  @Test func anUnknownIDGivesNoMarketplace() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills])

    #expect(try await registry.marketplace(id: Self.unknownID) == nil)
  }

  // MARK: - Add

  @Test func addAppendsTheSourceToTheEndOfTheStoredList() async throws {
    let (registry, storage) = Self.makeRegistry([Self.teamSkills])

    _ = try await registry.add(Self.skills)

    #expect(await storage.loadSources() == [Self.teamSkills, Self.skills])
  }

  @Test func addGivesTheEntryOfTheNewSource() async throws {
    let (registry, _) = Self.makeRegistry()

    let entry = try await registry.add(Self.skills)

    #expect(entry.id == Self.skillsID)
  }

  @Test func addOfADuplicateIDThrowsDuplicateMarketplace() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills])

    await #expect(throws: MarketplaceRegistryError.duplicateMarketplace(id: Self.teamSkillsID)) {
      try await registry.add(Self.otherTeamSkills)
    }
  }

  @Test func addOfADuplicateIDKeepsTheStoredList() async throws {
    let (registry, storage) = Self.makeRegistry([Self.teamSkills])

    _ = try? await registry.add(Self.otherTeamSkills)

    #expect(await storage.loadSources() == [Self.teamSkills])
  }

  // MARK: - Validation

  @Test func addOfASourceWithABadURLThrowsTheErrorOfTheParser() async throws {
    let (registry, _) = Self.makeRegistry()

    await #expect(throws: MarketplaceRegistryError.invalidSource(.unsupportedForm)) {
      try await registry.add(Self.badURL)
    }
  }

  @Test func addOfASourceWithAnUnusableKeyThrowsTheErrorOfTheParser() async throws {
    let (registry, _) = Self.makeRegistry()

    await #expect(throws: MarketplaceRegistryError.invalidSource(.unusableKey(Self.unusableAlias))) {
      try await registry.add(MarketplaceSource(Self.skills.url, alias: Self.unusableAlias))
    }
  }

  @Test func aStoredSourceWithABadURLThrowsInvalidSource() async throws {
    let (registry, _) = Self.makeRegistry([Self.badURL])

    await #expect(throws: MarketplaceRegistryError.invalidSource(.unsupportedForm)) {
      try await registry.marketplaces()
    }
  }

  @Test func aStoredListWithADuplicateIDThrowsDuplicateMarketplace() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills, Self.otherTeamSkills])

    await #expect(throws: MarketplaceRegistryError.duplicateMarketplace(id: Self.teamSkillsID)) {
      try await registry.marketplaces()
    }
  }

  // MARK: - Update

  @Test func updateReplacesTheSourceInItsPosition() async throws {
    let (registry, storage) = Self.makeRegistry([Self.skills, Self.teamSkills])

    _ = try await registry.update(id: Self.skillsID, to: Self.skillsOnBranch)

    #expect(await storage.loadSources() == [Self.skillsOnBranch, Self.teamSkills])
  }

  @Test func updateCanGiveTheMarketplaceAFreeNewID() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills, Self.teamSkills])

    _ = try await registry.update(id: Self.skillsID, to: Self.renamedSkills)

    #expect(try await registry.marketplaces().map(\.id) == [Self.renamedSkillsID, Self.teamSkillsID])
  }

  @Test func updateGivesTheNewEntry() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills])

    let entry = try await registry.update(id: Self.skillsID, to: Self.renamedSkills)

    #expect(entry.id == Self.renamedSkillsID)
  }

  @Test func updateOfAnUnknownIDThrowsUnknownMarketplace() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills])

    await #expect(throws: MarketplaceRegistryError.unknownMarketplace(id: Self.unknownID)) {
      try await registry.update(id: Self.unknownID, to: Self.teamSkills)
    }
  }

  @Test func updateToTheIDOfAnotherEntryThrowsDuplicateMarketplace() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills, Self.teamSkills])

    await #expect(throws: MarketplaceRegistryError.duplicateMarketplace(id: Self.teamSkillsID)) {
      try await registry.update(id: Self.skillsID, to: Self.otherTeamSkills)
    }
  }

  @Test func updateToTheIDOfAnotherEntryKeepsTheStoredList() async throws {
    let (registry, storage) = Self.makeRegistry([Self.skills, Self.teamSkills])

    _ = try? await registry.update(id: Self.skillsID, to: Self.otherTeamSkills)

    #expect(await storage.loadSources() == [Self.skills, Self.teamSkills])
  }

  @Test func updateToABadURLThrowsInvalidSource() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills])

    await #expect(throws: MarketplaceRegistryError.invalidSource(.unsupportedForm)) {
      try await registry.update(id: Self.skillsID, to: Self.badURL)
    }
  }

  // MARK: - Remove

  @Test func removeTakesTheSourceOutOfTheStoredList() async throws {
    let (registry, storage) = Self.makeRegistry([Self.skills, Self.teamSkills])

    _ = try await registry.remove(id: Self.skillsID)

    #expect(await storage.loadSources() == [Self.teamSkills])
  }

  @Test func removeGivesTheRemovedEntry() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills, Self.teamSkills])

    let entry = try await registry.remove(id: Self.teamSkillsID)

    #expect(entry.source == Self.teamSkills)
  }

  @Test func removeOfAnUnknownIDThrowsUnknownMarketplace() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills])

    await #expect(throws: MarketplaceRegistryError.unknownMarketplace(id: Self.unknownID)) {
      try await registry.remove(id: Self.unknownID)
    }
  }

  // MARK: - Reset

  @Test func resetGivesTheEntriesOfTheDefaultListInListOrder() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills], defaultSources: [Self.skills, Self.docs])

    let ids = try await registry.reset().map(\.id)

    #expect(ids == [Self.skillsID, Self.docsID])
  }

  @Test func resetStoresTheDefaultList() async throws {
    let (registry, storage) = Self.makeRegistry([Self.teamSkills], defaultSources: [Self.skills])

    _ = try await registry.reset()

    #expect(await storage.loadSources() == [Self.skills])
  }

  @Test func resetSendsARemovedChangeForAnOldIDThatTheNewListDoesNotHave() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills, Self.skills], defaultSources: [Self.skills])

    let changes = try await Self.changes(of: registry) { _ = try await registry.reset() }

    #expect(changes == [.removed(try Self.entry(Self.teamSkills))])
  }

  @Test func resetSendsAnAddedChangeForANewIDThatTheOldListDoesNotHave() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills], defaultSources: [Self.skills, Self.teamSkills])

    let changes = try await Self.changes(of: registry) { _ = try await registry.reset() }

    #expect(changes == [.added(try Self.entry(Self.teamSkills))])
  }

  @Test func resetSendsAnUpdatedChangeForAnIDWithAnotherSource() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills], defaultSources: [Self.skillsOnBranch])

    let changes = try await Self.changes(of: registry) { _ = try await registry.reset() }

    #expect(changes == [.updated(previousID: Self.skillsID, try Self.entry(Self.skillsOnBranch))])
  }

  @Test func resetToTheSameListSendsNoChange() async throws {
    let sources = [Self.skills, Self.teamSkills]
    let (registry, _) = Self.makeRegistry(sources, defaultSources: sources)

    let changes = try await Self.changes(of: registry) { _ = try await registry.reset() }

    #expect(changes.isEmpty)
  }

  @Test func resetSendsTheRemovalsFirstAndThenTheOtherChangesInNewListOrder() async throws {
    let (registry, _) = Self.makeRegistry(
      [Self.teamSkills, Self.skills, Self.docs],
      defaultSources: [Self.tools, Self.skillsOnBranch, Self.prompts])

    let changes = try await Self.changes(of: registry) { _ = try await registry.reset() }

    #expect(
      changes == [
        .removed(try Self.entry(Self.teamSkills)),
        .removed(try Self.entry(Self.docs)),
        .added(try Self.entry(Self.tools)),
        .updated(previousID: Self.skillsID, try Self.entry(Self.skillsOnBranch)),
        .added(try Self.entry(Self.prompts)),
      ])
  }

  @Test func resetToAListWithADuplicateIDThrowsDuplicateMarketplace() async throws {
    let (registry, _) = Self.makeRegistry(defaultSources: [Self.teamSkills, Self.otherTeamSkills])

    await #expect(throws: MarketplaceRegistryError.duplicateMarketplace(id: Self.teamSkillsID)) {
      try await registry.reset()
    }
  }

  @Test func resetToAListWithABadSourceThrowsInvalidSource() async throws {
    let (registry, _) = Self.makeRegistry(defaultSources: [Self.badURL])

    await #expect(throws: MarketplaceRegistryError.invalidSource(.unsupportedForm)) {
      try await registry.reset()
    }
  }

  @Test func resetToAListThatIsNotValidSendsNoChange() async throws {
    let (registry, storage) = Self.makeRegistry([Self.teamSkills], defaultSources: [Self.badURL])

    let changes = try await Self.changes(of: registry) {
      _ = try? await registry.reset()
      await storage.saveSources([])
    }

    #expect(changes.isEmpty)
  }

  @Test func aStorageErrorOfAResetComesOutUnchanged() async throws {
    let registry = MarketplaceRegistry(storage: FailingMarketplaceSourceStorage(failing: .save))

    await #expect(throws: FailingMarketplaceSourceStorage.Failure.save) {
      try await registry.reset()
    }
  }

  @Test func aStorageErrorOfAResetSendsNoChange() async throws {
    let storage = FailingMarketplaceSourceStorage(failing: .save, sources: [Self.teamSkills])
    let registry = MarketplaceRegistry(storage: storage)

    let changes = try await Self.changes(of: registry) {
      _ = try? await registry.reset()
      await storage.stopFailing()
    }

    #expect(changes.isEmpty)
  }

  @Test func anAddThatComesDuringAResetRunsAfterTheReset() async throws {
    let storage = GatedResetMarketplaceSourceStorage(sources: [Self.teamSkills], defaultSources: [Self.skills])
    let registry = MarketplaceRegistry(storage: storage)
    var startedResets = storage.startedResets.makeAsyncIterator()

    async let reset = registry.reset()
    await startedResets.next()
    async let added = registry.add(Self.docs)
    try await Task.sleep(for: Self.addArrivalTime)
    await storage.openGate()
    _ = try await (reset, added)

    #expect(await storage.sources == [Self.skills, Self.docs])
  }

  // MARK: - Changes

  @Test func addSendsAnAddedChange() async throws {
    let (registry, _) = Self.makeRegistry()
    var changes = registry.changes().makeAsyncIterator()

    let entry = try await registry.add(Self.skills)

    #expect(await changes.next() == .added(entry))
  }

  @Test func updateSendsAnUpdatedChangeWithThePreviousID() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills])
    var changes = registry.changes().makeAsyncIterator()

    let entry = try await registry.update(id: Self.skillsID, to: Self.renamedSkills)

    #expect(await changes.next() == .updated(previousID: Self.skillsID, entry))
  }

  @Test func removeSendsARemovedChange() async throws {
    let (registry, _) = Self.makeRegistry([Self.skills])
    var changes = registry.changes().makeAsyncIterator()

    let entry = try await registry.remove(id: Self.skillsID)

    #expect(await changes.next() == .removed(entry))
  }

  @Test func eachWriteSendsOneChangeInOrder() async throws {
    let (registry, _) = Self.makeRegistry()
    var changes = registry.changes().makeAsyncIterator()

    _ = try await registry.add(Self.skills)
    _ = try await registry.add(Self.teamSkills)
    _ = try await registry.remove(id: Self.skillsID)

    #expect(await changes.next() == .added(try Self.entry(Self.skills)))
    #expect(await changes.next() == .added(try Self.entry(Self.teamSkills)))
    #expect(await changes.next() == .removed(try Self.entry(Self.skills)))
  }

  @Test func aFailedWriteSendsNoChange() async throws {
    let (registry, _) = Self.makeRegistry([Self.teamSkills])
    var changes = registry.changes().makeAsyncIterator()

    _ = try? await registry.add(Self.otherTeamSkills)
    let entry = try await registry.add(Self.skills)

    #expect(await changes.next() == .added(entry))
  }

  // MARK: - Concurrency

  @Test func concurrentAddsAllLandInTheStoredList() async throws {
    let (registry, storage) = Self.makeRegistry()
    let sources = (0..<Self.concurrentAddCount).map { MarketplaceSource("github:acme/skills-\($0)") }

    try await withThrowingTaskGroup(of: MarketplaceEntry.self) { group in
      for source in sources {
        group.addTask { try await registry.add(source) }
      }
      try await group.waitForAll()
    }

    #expect(Set(await storage.loadSources()) == Set(sources))
  }

  // MARK: - Storage errors

  @Test func aLoadErrorOfTheStorageComesOutUnchanged() async throws {
    let registry = MarketplaceRegistry(storage: FailingMarketplaceSourceStorage(failing: .load))

    await #expect(throws: FailingMarketplaceSourceStorage.Failure.load) {
      try await registry.add(Self.skills)
    }
  }

  @Test func aSaveErrorOfTheStorageComesOutUnchanged() async throws {
    let registry = MarketplaceRegistry(storage: FailingMarketplaceSourceStorage(failing: .save))

    await #expect(throws: FailingMarketplaceSourceStorage.Failure.save) {
      try await registry.add(Self.skills)
    }
  }

  @Test func aSaveErrorKeepsTheStoredList() async throws {
    let storage = FailingMarketplaceSourceStorage(failing: .save, sources: [Self.teamSkills])
    let registry = MarketplaceRegistry(storage: storage)

    _ = try? await registry.remove(id: Self.teamSkillsID)

    #expect(await storage.sources == [Self.teamSkills])
  }

  @Test func aSaveErrorSendsNoChange() async throws {
    let storage = FailingMarketplaceSourceStorage(failing: .save)
    let registry = MarketplaceRegistry(storage: storage)
    var changes = registry.changes().makeAsyncIterator()

    _ = try? await registry.add(Self.teamSkills)
    await storage.stopFailing()
    let entry = try await registry.add(Self.skills)

    #expect(await changes.next() == .added(entry))
  }
}

/// A ``MarketplaceSourceStorage`` that throws from one of its two calls
/// until ``stopFailing()`` runs.
private actor FailingMarketplaceSourceStorage: MarketplaceSourceStorage {
  /// The error of each call that fails.
  enum Failure: Error, Equatable {
    /// ``loadSources()`` fails.
    case load

    /// ``saveSources(_:)`` fails.
    case save
  }

  /// The call that fails, or `nil` when no call fails.
  private var failing: Failure?

  /// The stored list, in list order.
  private(set) var sources: [MarketplaceSource]

  /// Makes a storage that fails one call, or no call.
  ///
  /// - Parameters:
  ///   - failing: The call that fails, or `nil` when no call fails.
  ///   - sources: The list at the start.
  init(failing: Failure?, sources: [MarketplaceSource] = []) {
    self.failing = failing
    self.sources = sources
  }

  /// Makes each later call succeed.
  func stopFailing() {
    failing = nil
  }

  /// Gives the stored list, or throws ``Failure/load``.
  ///
  /// - Returns: The sources, in list order.
  func loadSources() throws -> [MarketplaceSource] {
    if failing == .load {
      throw Failure.load
    }
    return sources
  }

  /// Replaces the stored list, or throws ``Failure/save`` and keeps it.
  ///
  /// - Parameter sources: The full new list, in list order.
  func saveSources(_ sources: [MarketplaceSource]) throws {
    if failing == .save {
      throw Failure.save
    }
    self.sources = sources
  }
}

/// A ``MarketplaceSourceStorage`` whose ``resetSources()`` waits until the
/// test calls ``openGate()``.
///
/// A reset sends one value on ``startedResets`` when it starts to wait.
private actor GatedResetMarketplaceSourceStorage: MarketplaceSourceStorage {
  /// One value for each reset that started to wait at the gate.
  nonisolated let startedResets: AsyncStream<Void>

  /// Sends the values of ``startedResets``.
  private let resetStarted: AsyncStream<Void>.Continuation

  /// The stored list, in list order.
  private(set) var sources: [MarketplaceSource]

  /// The list that a reset stores.
  private let defaultSources: [MarketplaceSource]

  /// The reset that waits at the gate, or `nil` when no reset waits.
  private var waitingReset: CheckedContinuation<Void, Never>?

  /// Makes a storage that holds `sources`.
  ///
  /// - Parameters:
  ///   - sources: The list at the start.
  ///   - defaultSources: The list that a reset stores.
  init(sources: [MarketplaceSource], defaultSources: [MarketplaceSource]) {
    (startedResets, resetStarted) = AsyncStream.makeStream(of: Void.self)
    self.sources = sources
    self.defaultSources = defaultSources
  }

  /// Lets the waiting reset continue.
  func openGate() {
    waitingReset?.resume()
    waitingReset = nil
  }

  /// Gives the stored list.
  ///
  /// - Returns: The sources, in list order.
  func loadSources() -> [MarketplaceSource] {
    sources
  }

  /// Replaces the stored list.
  ///
  /// - Parameter sources: The full new list, in list order.
  func saveSources(_ sources: [MarketplaceSource]) {
    self.sources = sources
  }

  /// Waits at the gate, and then stores the default list.
  ///
  /// - Returns: The default list.
  func resetSources() async -> [MarketplaceSource] {
    await withCheckedContinuation { continuation in
      waitingReset = continuation
      resetStarted.yield()
    }
    sources = defaultSources
    return sources
  }
}
