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

  /// Makes the entry of a source that the tests know is valid.
  ///
  /// - Parameter source: The source.
  /// - Returns: The entry.
  private static func entry(_ source: MarketplaceSource) throws -> MarketplaceEntry {
    try MarketplaceEntry(source: source)
  }

  /// Makes a registry over an in-memory storage that holds `sources`.
  ///
  /// - Parameter sources: The list that the storage holds at the start.
  /// - Returns: The registry and its storage.
  private static func makeRegistry(
    _ sources: [MarketplaceSource] = []
  ) -> (registry: MarketplaceRegistry, storage: InMemoryMarketplaceSourceStorage) {
    let storage = InMemoryMarketplaceSourceStorage(sources: sources)
    return (MarketplaceRegistry(storage: storage), storage)
  }

  // MARK: - Storage

  @Test func theInMemoryStorageGivesBackTheListThatItSaved() async throws {
    let storage: any MarketplaceSourceStorage = InMemoryMarketplaceSourceStorage()

    try await storage.saveSources([Self.teamSkills, Self.skills])

    #expect(try await storage.loadSources() == [Self.teamSkills, Self.skills])
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

  /// Makes a storage that fails one call.
  ///
  /// - Parameters:
  ///   - failing: The call that fails.
  ///   - sources: The list at the start.
  init(failing: Failure, sources: [MarketplaceSource] = []) {
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
