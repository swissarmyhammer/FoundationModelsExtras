import FixtureSupport
import Foundation
import MarketplaceFixtures
import Testing

@testable import Marketplace

/// Tests for ``MarketplaceListing`` and for
/// ``MarketplaceStore/listings(of:cacheDirectory:)``: the public read of one
/// marketplace list (marketplace.md §5.3 and §7.2).
///
/// The call reads the state file of the cache and opens no connection, thus
/// each test writes a record on the disk, or calls a pin that writes one, and
/// then reads the listing back.
@Suite("Marketplace listing")
struct MarketplaceListingTests {
  /// The URL of a git source that no test fetches.
  private static let gitURL = "https://github.com/swissarmyhammer/skills.git"

  /// The pre-fetch key of ``gitURL``, which is its repository name.
  private static let gitKey = "skills"

  /// The commit of the snapshot that a record names.
  private static let commit = "0123456789abcdef0123456789abcdef01234567"

  /// A second commit, which a pin of the host holds.
  private static let pinnedCommit = "89abcdef0123456789abcdef0123456789abcdef"

  /// The `version` field of the catalog of a snapshot.
  private static let catalogVersion = "1.4.0"

  /// The `name` field of the catalog, which is the display id.
  private static let displayID = "swissarmyhammer-skills"

  /// The message of the last failure that the store recorded.
  private static let failureMessage = "The remote refused the connection."

  /// When the store last asked the remote for its head, in seconds after
  /// 1970.
  private static let lastCheckedSeconds: TimeInterval = 1_700_000_000

  /// A URL of no form that the parser supports.
  private static let unsupportedURL = "ftp://example.com/skills.git"

  /// The alias of the source that carries ``unsupportedURL``.
  private static let unsupportedAlias = "team"

  /// The text that starts a `file://` URL.
  private static let fileURLPrefix = "file://"

  // MARK: - Whether the marketplace holds one commit (§8.3)

  @Test func aPinOfTheHostSaysThatTheMarketplaceHoldsOneCommit() async throws {
    let source = MarketplaceSource(Self.gitURL)
    let fixture = try MarketplaceStoreFixture(sources: [source])
    try await fixture.store.pin(Self.gitKey, sha: Self.pinnedCommit)

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: fixture.cacheDirectory).first)

    #expect(listing.holdsOneCommit)
  }

  @Test func anUnpinOfTheHostBeatsTheShaFieldOfTheSource() async throws {
    let source = MarketplaceSource(Self.gitURL, sha: Self.commit)
    let fixture = try MarketplaceStoreFixture(sources: [source])
    try await fixture.store.unpin(Self.gitKey)

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: fixture.cacheDirectory).first)

    #expect(!listing.holdsOneCommit)
  }

  @Test func theShaFieldOfASourceSaysThatTheMarketplaceHoldsOneCommit() throws {
    let source = MarketplaceSource(Self.gitURL, sha: Self.commit)
    let cacheDirectory = try TemporaryDirectory.make()

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.holdsOneCommit)
  }

  @Test func aMarketplaceThatFollowsARefHoldsNoOneCommit() throws {
    let source = MarketplaceSource(Self.gitURL, ref: "main")
    let cacheDirectory = try TemporaryDirectory.make()

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(!listing.holdsOneCommit)
  }

  // MARK: - What the snapshot gives (§7.2)

  @Test func aMarketplaceWithNoSnapshotCarriesNoCommit() throws {
    let source = MarketplaceSource(Self.gitURL)
    let cacheDirectory = try TemporaryDirectory.make()
    let checked = Date(timeIntervalSince1970: Self.lastCheckedSeconds)
    try Self.write(
      record: MarketplaceStateRecord(url: Self.gitURL, lastChecked: checked),
      ofSource: source, inCacheDirectory: cacheDirectory)

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.currentSha == nil)
    #expect(listing.catalogVersion == nil)
    #expect(listing.lastChecked == checked)
  }

  @Test func anInstalledMarketplaceCarriesItsCommitAndItsCatalogVersion() throws {
    let source = MarketplaceSource(Self.gitURL)
    let cacheDirectory = try TemporaryDirectory.make()
    try Self.write(
      record: MarketplaceStateRecord(
        url: Self.gitURL, currentSha: Self.commit, catalogVersion: Self.catalogVersion),
      ofSource: source, inCacheDirectory: cacheDirectory)

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.currentSha == Self.commit)
    #expect(listing.catalogVersion == Self.catalogVersion)
  }

  // MARK: - The name of the marketplace (§5.3)

  @Test func aListingCarriesTheDisplayIDOfTheCatalog() throws {
    let source = MarketplaceSource(Self.gitURL)
    let cacheDirectory = try TemporaryDirectory.make()
    try Self.write(
      record: MarketplaceStateRecord(url: Self.gitURL, displayID: Self.displayID),
      ofSource: source, inCacheDirectory: cacheDirectory)

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.id == Self.displayID)
  }

  @Test func aMarketplaceWithNoDisplayIDIsNamedByItsPreFetchKey() throws {
    let source = MarketplaceSource(Self.gitURL)
    let cacheDirectory = try TemporaryDirectory.make()

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.id == Self.gitKey)
    #expect(listing.key == Self.gitKey)
  }

  // MARK: - A folder on this computer (§5.1)

  @Test func aFolderOnThisComputerSaysSo() throws {
    let folder = try TemporaryDirectory.make()
    let source = MarketplaceSource("\(Self.fileURLPrefix)\(folder.path)")
    let cacheDirectory = try TemporaryDirectory.make()

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.isLocalFolder)
    #expect(listing.url == "\(Self.fileURLPrefix)\(folder.path)")
  }

  @Test func aGitMarketplaceIsNoFolderOnThisComputer() throws {
    let source = MarketplaceSource(Self.gitURL)
    let cacheDirectory = try TemporaryDirectory.make()

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(!listing.isLocalFolder)
    #expect(listing.url == Self.gitURL)
  }

  // MARK: - What went wrong (§6.2)

  @Test func aListingCarriesTheMessageOfTheLastFailure() throws {
    let source = MarketplaceSource(Self.gitURL)
    let cacheDirectory = try TemporaryDirectory.make()
    try Self.write(
      record: MarketplaceStateRecord(url: Self.gitURL, lastError: Self.failureMessage),
      ofSource: source, inCacheDirectory: cacheDirectory)

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.lastError == Self.failureMessage)
  }

  @Test func aSourceOfNoSupportedFormCarriesTheMessageOfTheParser() throws {
    let source = MarketplaceSource(Self.unsupportedURL, alias: Self.unsupportedAlias)
    let cacheDirectory = try TemporaryDirectory.make()

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(listing.lastError == String(describing: MarketplaceSourceError.unsupportedForm))
    #expect(listing.id == Self.unsupportedAlias)
    #expect(listing.key == nil)
    #expect(listing.url == nil)
  }

  // MARK: - What a consumer of the public API alone can build

  @Test func oneListingGivesTheSixColumnsOfAList() throws {
    let source = MarketplaceSource(Self.gitURL)
    let cacheDirectory = try TemporaryDirectory.make()
    let checked = Date(timeIntervalSince1970: Self.lastCheckedSeconds)
    try Self.write(
      record: MarketplaceStateRecord(
        url: Self.gitURL, currentSha: Self.commit, catalogVersion: Self.catalogVersion,
        displayID: Self.displayID, lastChecked: checked),
      ofSource: source, inCacheDirectory: cacheDirectory)

    let listing = try #require(
      MarketplaceStore.listings(of: [source], cacheDirectory: cacheDirectory).first)

    #expect(
      Self.columns(of: listing) == [
        Self.displayID, Self.gitURL, Self.commit, Self.catalogVersion,
        checked.formatted(.iso8601), Self.readyStatus,
      ])
  }

  @Test func oneCallGivesOneListingForEachSourceInListOrder() throws {
    let sources = [
      MarketplaceSource(Self.gitURL),
      MarketplaceSource(Self.unsupportedURL, alias: Self.unsupportedAlias),
    ]
    let cacheDirectory = try TemporaryDirectory.make()

    let listings = MarketplaceStore.listings(of: sources, cacheDirectory: cacheDirectory)

    #expect(listings.map(\.id) == [Self.gitKey, Self.unsupportedAlias])
  }

  // MARK: - The environment variables of the cache (§7.1 and §7.5)

  @Test func theStoreNamesTheCacheVariableAndTheSeedVariable() {
    #expect(MarketplaceStore.cacheDirectoryVariable == "SKILLS_MARKETPLACE_CACHE")
    #expect(MarketplaceStore.seedDirectoryVariable == "SKILLS_MARKETPLACE_SEED")
  }

  @Test func theCacheVariableNamesTheVariableThatTheStoreReads() throws {
    let folder = try TemporaryDirectory.make()

    let directory = MarketplaceStore.cacheDirectory(
      environment: [MarketplaceStore.cacheDirectoryVariable: folder.path])

    #expect(directory.path == folder.path)
  }

  @Test func theSeedVariableNamesTheVariableThatTheStoreReads() throws {
    let folder = try TemporaryDirectory.make()

    let directory = MarketplaceCache.seedDirectory(
      environment: [MarketplaceStore.seedDirectoryVariable: folder.path])

    #expect(directory?.path == folder.path)
  }

  // MARK: - Support

  /// The status word of a marketplace that is installed and follows a ref.
  private static let readyStatus = "ready"

  /// The status word of a marketplace that holds one commit.
  private static let pinnedStatus = "pinned"

  /// The status word of a marketplace that has no snapshot yet.
  private static let notInstalledStatus = "not installed"

  /// The status word of a folder on this computer.
  private static let localStatus = "local folder"

  /// The text of a column that a listing gives no value for.
  private static let emptyColumn = "-"

  /// The six columns of one row of a list: the id, the URL, the current
  /// commit, the catalog version, the last check, and the status.
  ///
  /// The call reads the listing only, thus it proves that a consumer of the
  /// public API alone writes the whole row.
  ///
  /// - Parameter listing: The listing to read.
  /// - Returns: The text of each column, in column order.
  private static func columns(of listing: MarketplaceListing) -> [String] {
    [
      listing.id,
      listing.url ?? emptyColumn,
      listing.currentSha ?? emptyColumn,
      listing.catalogVersion ?? emptyColumn,
      listing.lastChecked.map { $0.formatted(.iso8601) } ?? emptyColumn,
      status(of: listing),
    ]
  }

  /// The status column of one row.
  ///
  /// - Parameter listing: The listing to read.
  /// - Returns: The status word, or the message of the last failure.
  private static func status(of listing: MarketplaceListing) -> String {
    if listing.isLocalFolder {
      return localStatus
    }
    if let lastError = listing.lastError {
      return lastError
    }
    if listing.currentSha == nil {
      return notInstalledStatus
    }
    return listing.holdsOneCommit ? pinnedStatus : readyStatus
  }

  /// Writes one state record into the state file of a cache directory.
  ///
  /// The record is keyed by the cache folder name of the source, which is
  /// what ``MarketplaceStore/listings(of:cacheDirectory:)`` looks it up by.
  ///
  /// - Parameters:
  ///   - record: The record to write.
  ///   - source: The source that the record belongs to.
  ///   - cacheDirectory: The cache directory that holds the state file.
  /// - Throws: ``MarketplaceSourceError`` when the source gives no
  ///   pre-fetch key, else the error of the file write.
  private static func write(
    record: MarketplaceStateRecord, ofSource source: MarketplaceSource,
    inCacheDirectory cacheDirectory: URL
  ) throws {
    let folderName = MarketplaceIdentity.cacheFolderName(
      key: try MarketplaceIdentity.preFetchKey(for: source),
      normalizedURL: try MarketplaceLocation(source: source).normalizedURL)
    try MarketplaceState(marketplaces: [folderName: record])
      .save(to: MarketplaceCache.stateFile(inCacheDirectory: cacheDirectory))
  }
}
