/// Reads and changes the list of marketplace sources of a host, one
/// marketplace at a time.
///
/// The registry keeps no copy of the list. Each operation reads the list from
/// the ``MarketplaceSourceStorage``, thus a change that the host makes in
/// another place is not lost.
///
/// The registry runs its writes one at a time, in the order of the calls. A
/// write waits for the storage two times, to read the list and to save it,
/// thus two writes that ran together could each save a list without the
/// change of the other.
///
/// ``MarketplaceStore`` keeps the source list that it got at its init. Thus a
/// host makes a new store from ``marketplaces()`` when the list changes.
public actor MarketplaceRegistry {
  /// The place where the host keeps the list.
  private let storage: any MarketplaceSourceStorage

  /// Gives each saved change to each subscriber of ``changes()``.
  private let broadcaster = EventBroadcaster<MarketplaceRegistryChange>()

  /// Whether a write runs now.
  private var isWriting = false

  /// The writes that wait for the current write, in call order.
  private var waitingWrites: [CheckedContinuation<Void, Never>] = []

  /// Makes a registry over `storage`.
  ///
  /// - Parameter storage: The place where the host keeps the list.
  public init(storage: any MarketplaceSourceStorage) {
    self.storage = storage
  }

  /// Gives each marketplace of the stored list.
  ///
  /// - Returns: One entry for each stored source, in list order.
  /// - Throws: ``MarketplaceRegistryError`` when the stored list is not
  ///   valid, or the error of the storage when it cannot read the list.
  public func marketplaces() async throws -> [MarketplaceEntry] {
    try Self.entries(of: await storage.loadSources())
  }

  /// Gives one marketplace of the stored list.
  ///
  /// - Parameter id: The id of the marketplace.
  /// - Returns: The entry with that id, or `nil` when no entry has it.
  /// - Throws: ``MarketplaceRegistryError`` when the stored list is not
  ///   valid, or the error of the storage when it cannot read the list.
  public func marketplace(id: String) async throws -> MarketplaceEntry? {
    try await marketplaces().first { $0.id == id }
  }

  /// Adds a marketplace to the end of the stored list.
  ///
  /// - Parameter source: The source of the new marketplace.
  /// - Returns: The entry of the new marketplace.
  /// - Throws: ``MarketplaceRegistryError/duplicateMarketplace(id:)`` when
  ///   the list has the id already, another ``MarketplaceRegistryError``
  ///   when the source or the stored list is not valid, or the error of the
  ///   storage.
  public func add(_ source: MarketplaceSource) async throws -> MarketplaceEntry {
    let entry = try MarketplaceEntry(source: source)
    try await write {
      try await save(marketplaces() + [entry], change: .added(entry))
    }
    return entry
  }

  /// Replaces the source of one marketplace, in its position in the list.
  ///
  /// The new source can have a different id when no other marketplace of
  /// the list has that id.
  ///
  /// - Parameters:
  ///   - id: The id of the marketplace to change.
  ///   - source: The new source.
  /// - Returns: The entry of the new source.
  /// - Throws: ``MarketplaceRegistryError/unknownMarketplace(id:)`` when no
  ///   marketplace has `id`,
  ///   ``MarketplaceRegistryError/duplicateMarketplace(id:)`` when another
  ///   marketplace has the new id, another ``MarketplaceRegistryError`` when
  ///   the source or the stored list is not valid, or the error of the
  ///   storage.
  public func update(id: String, to source: MarketplaceSource) async throws -> MarketplaceEntry {
    let entry = try MarketplaceEntry(source: source)
    try await write {
      var entries = try await marketplaces()
      entries[try Self.index(of: id, in: entries)] = entry
      try await save(entries, change: .updated(previousID: id, entry))
    }
    return entry
  }

  /// Removes one marketplace from the stored list.
  ///
  /// - Parameter id: The id of the marketplace to remove.
  /// - Returns: The removed entry.
  /// - Throws: ``MarketplaceRegistryError/unknownMarketplace(id:)`` when no
  ///   marketplace has `id`, another ``MarketplaceRegistryError`` when the
  ///   stored list is not valid, or the error of the storage.
  public func remove(id: String) async throws -> MarketplaceEntry {
    try await write {
      var entries = try await marketplaces()
      let removed = entries.remove(at: try Self.index(of: id, in: entries))
      try await save(entries, change: .removed(removed))
      return removed
    }
  }

  /// Replaces the stored list with the default list of the host.
  ///
  /// The registry reads the stored list, and then calls
  /// ``MarketplaceSourceStorage/resetSources()``. It compares the two lists
  /// by id, and sends one change for each marketplace that the reset
  /// changed:
  ///
  /// - ``MarketplaceRegistryChange/removed(_:)`` for each old id that the
  ///   new list does not have.
  /// - ``MarketplaceRegistryChange/added(_:)`` for each new id that the old
  ///   list does not have.
  /// - ``MarketplaceRegistryChange/updated(previousID:_:)`` for each id that
  ///   the two lists have with a different source.
  ///
  /// First come the removals, in the order of the old list. Then come the
  /// additions and the updates, in the order of the new list. When the two
  /// lists are the same, the reset sends no change.
  ///
  /// - Returns: One entry for each source of the new list, in list order.
  /// - Throws: ``MarketplaceRegistryError`` when the stored list or the new
  ///   list is not valid, or the error of the storage. A failed reset sends
  ///   no change. When the new list is not valid, the storage has already
  ///   cleared the value of the host: the next read throws the same error
  ///   until the host corrects the list.
  public func reset() async throws -> [MarketplaceEntry] {
    try await write {
      let oldEntries = try await marketplaces()
      let newEntries = try Self.entries(of: await storage.resetSources())
      for change in Self.changes(from: oldEntries, to: newEntries) {
        broadcaster.publish(change)
      }
      return newEntries
    }
  }

  /// Gives each change that the registry saves from this point forward.
  ///
  /// A failed operation sends no change.
  ///
  /// - Returns: A new stream for one subscriber. It sends the changes in the
  ///   order of the saves.
  public nonisolated func changes() -> AsyncStream<MarketplaceRegistryChange> {
    broadcaster.subscribe()
  }

  /// Runs one write after each earlier write has ended.
  ///
  /// - Parameter body: The write: it reads the list, changes it, and saves
  ///   it.
  /// - Returns: The result of `body`.
  /// - Throws: The error of `body`.
  private func write<Result: Sendable>(_ body: () async throws -> Result) async throws -> Result {
    await startWrite()
    defer { endWrite() }
    return try await body()
  }

  /// Waits until no other write runs, and then marks a write as running.
  private func startWrite() async {
    guard isWriting else {
      isWriting = true
      return
    }
    await withCheckedContinuation { waitingWrites.append($0) }
  }

  /// Gives the turn to the next waiting write, or marks that no write runs.
  private func endWrite() {
    guard !waitingWrites.isEmpty else {
      isWriting = false
      return
    }
    waitingWrites.removeFirst().resume()
  }

  /// Validates a new list, saves it, and then sends its change.
  ///
  /// - Parameters:
  ///   - entries: The full new list, in list order.
  ///   - change: The change that the new list makes.
  /// - Throws: ``MarketplaceRegistryError/duplicateMarketplace(id:)`` when
  ///   two entries have the same id, or the error of the storage. The
  ///   change is not sent when the call throws.
  private func save(_ entries: [MarketplaceEntry], change: MarketplaceRegistryChange) async throws {
    try Self.requireUniqueIDs(entries)
    try await storage.saveSources(entries.map(\.source))
    broadcaster.publish(change)
  }

  /// Makes one entry for each source of a list, and validates the list.
  ///
  /// - Parameter sources: The sources, in list order.
  /// - Returns: The entries, in list order.
  /// - Throws: ``MarketplaceRegistryError`` when a source gives no id, or
  ///   when two sources have the same id.
  private static func entries(of sources: [MarketplaceSource]) throws -> [MarketplaceEntry] {
    let entries = try sources.map(MarketplaceEntry.init(source:))
    try requireUniqueIDs(entries)
    return entries
  }

  /// Compares two lists by id, and gives the changes from the old list to
  /// the new list.
  ///
  /// - Parameters:
  ///   - oldEntries: The old list, with no two entries with the same id.
  ///   - newEntries: The new list, with no two entries with the same id.
  /// - Returns: A removal for each old id that the new list does not have,
  ///   in the order of the old list. Then an addition for each new id that
  ///   the old list does not have, and an update for each id with a
  ///   different source, in the order of the new list.
  private static func changes(
    from oldEntries: [MarketplaceEntry],
    to newEntries: [MarketplaceEntry]
  ) -> [MarketplaceRegistryChange] {
    let oldEntriesByID = Dictionary(uniqueKeysWithValues: oldEntries.map { ($0.id, $0) })
    let newIDs = Set(newEntries.map(\.id))
    let removals = oldEntries.filter { !newIDs.contains($0.id) }.map(MarketplaceRegistryChange.removed)
    let otherChanges = newEntries.compactMap { entry -> MarketplaceRegistryChange? in
      guard let oldEntry = oldEntriesByID[entry.id] else {
        return .added(entry)
      }
      return oldEntry.source == entry.source ? nil : .updated(previousID: entry.id, entry)
    }
    return removals + otherChanges
  }

  /// Finds the position of one marketplace in a list.
  ///
  /// - Parameters:
  ///   - id: The id of the marketplace.
  ///   - entries: The entries, in list order.
  /// - Returns: The index of the entry with that id.
  /// - Throws: ``MarketplaceRegistryError/unknownMarketplace(id:)`` when no
  ///   entry has `id`.
  private static func index(of id: String, in entries: [MarketplaceEntry]) throws -> Int {
    guard let index = entries.firstIndex(where: { $0.id == id }) else {
      throw MarketplaceRegistryError.unknownMarketplace(id: id)
    }
    return index
  }

  /// Requires that no two entries of a list have the same id.
  ///
  /// - Parameter entries: The entries, in list order.
  /// - Throws: ``MarketplaceRegistryError/duplicateMarketplace(id:)`` for the
  ///   first entry whose id an earlier entry has.
  private static func requireUniqueIDs(_ entries: [MarketplaceEntry]) throws {
    var seen: Set<String> = []
    for entry in entries where !seen.insert(entry.id).inserted {
      throw MarketplaceRegistryError.duplicateMarketplace(id: entry.id)
    }
  }
}
