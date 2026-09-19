import FixtureSupport
import Foundation
import Testing

@testable import Marketplace

/// Proves the cache of marketplace.md §7: where the cache folder is, what one
/// marketplace folder holds, how an install swaps `current`, how cleanup keeps
/// two snapshots, and how `state.json` reads and writes.
///
/// Each test makes its own temporary cache, so no test reads the real home
/// folder or the files of another test.
@Suite("Marketplace cache")
struct MarketplaceCacheTests {
  // MARK: - Fixture

  /// The number of hex digits of a commit sha.
  private static let shaHexLength = 40

  /// The base of a hex digit.
  private static let hexRadix = 16

  /// The number of snapshots that the install tests write.
  private static let exampleShaCount = 4

  /// The number of snapshots that cleanup keeps: the one that `current`
  /// names, and the one before it.
  private static let keptShaCount = 2

  /// The number of installs of the cleanup tests: one more than the cache
  /// keeps.
  private static let cleanupInstallCount = keptShaCount + 1

  /// One sha for each install of a test, each with its own hex digit.
  private static let exampleShas = (0..<exampleShaCount).map { index in
    String(repeating: String(index, radix: hexRadix), count: shaHexLength)
  }

  /// The ref that the install tests write.
  private static let exampleRef = "main"

  /// The file that each staged snapshot holds. Its text is the sha of the
  /// snapshot, so a reader can tell which snapshot it read.
  private static let markerPath = "example-skill/SKILL.md"

  /// The name of the folder that holds the staged snapshots of a test.
  private static let stagingDirectoryName = "staging"

  /// A temporary cache with one marketplace folder in it.
  private struct CacheFixture: Sendable {
    /// The cache directory that holds `state.json` and the marketplace
    /// folders.
    let root: URL

    /// The cache of the one marketplace of the fixture.
    let cache: MarketplaceCache

    /// Makes a new temporary cache directory.
    ///
    /// - Throws: The error of the folder.
    init() throws {
      root = try TemporaryDirectory.make()
      cache = MarketplaceCache(
        root: root,
        folderName: MarketplaceIdentity.cacheFolderName(
          key: "skills", normalizedURL: "https://example.test/acme/skills.git"))
    }

    /// Deletes the temporary cache directory.
    func remove() {
      try? FileManager.default.removeItem(at: root)
    }

    /// Writes a staged snapshot folder that holds one marker file.
    ///
    /// - Parameter sha: The commit of the snapshot. It is the name of the
    ///   staged folder and the text of the marker file.
    /// - Returns: The staged folder.
    /// - Throws: The error of the folder or of the file write.
    func stageSnapshot(sha: String) throws -> URL {
      let staged = root
        .appendingPathComponent(stagingDirectoryName, isDirectory: true)
        .appendingPathComponent(sha, isDirectory: true)
      try MarketplaceTestSupport.writeFile(
        text: sha, to: staged.appendingPathComponent(markerPath))
      return staged
    }

    /// Stages one snapshot and installs it.
    ///
    /// - Parameter sha: The commit of the snapshot.
    /// - Throws: The error of the staging or of the install.
    func install(sha: String) throws {
      try cache.install(snapshotAt: try stageSnapshot(sha: sha), sha: sha, ref: exampleRef)
    }

    /// Reads the marker file of the snapshot that `current` names.
    ///
    /// - Returns: The sha that the marker file holds, or `nil` when no
    ///   install has happened yet.
    /// - Throws: The error of the file read. A read that throws means that
    ///   `current` named a folder that is missing or not complete.
    func readCurrentMarker() throws -> String? {
      try cache.currentSnapshot().map { current in
        try String(
          contentsOf: current.appendingPathComponent(markerPath), encoding: .utf8)
      }
    }

    /// Reads `current` again and again, and counts the reads that gave a
    /// complete snapshot.
    ///
    /// - Parameter times: How many reads to do.
    /// - Returns: The number of reads whose marker file named the snapshot
    ///   that `current` named.
    /// - Throws: The error of a file read.
    func countCompleteReads(times: Int) async throws -> Int {
      var complete = 0
      for _ in 0..<times {
        if let marker = try readCurrentMarker(), marker == cache.currentSha() {
          complete += 1
        }
        await Task.yield()
      }
      return complete
    }
  }

  // MARK: - Location

  @Test func theVariableNamesTheCacheDirectory() {
    let directory = MarketplaceCache.cacheDirectory(
      environment: [MarketplaceCache.cacheVariable: "/tmp/skills-cache"])

    #expect(directory.path == "/tmp/skills-cache")
  }

  @Test func anEmptyVariableFallsBackToTheHomeCache() {
    let directory = MarketplaceCache.cacheDirectory(
      environment: [MarketplaceCache.cacheVariable: ""])

    #expect(directory.path == Self.homeCachePath)
  }

  @Test func anAbsentVariableFallsBackToTheHomeCache() {
    let directory = MarketplaceCache.cacheDirectory(environment: [:])

    #expect(directory.path == Self.homeCachePath)
  }

  @Test func aTildeInTheVariableExpandsToTheHomeFolder() {
    let directory = MarketplaceCache.cacheDirectory(
      environment: [MarketplaceCache.cacheVariable: "~/skills-cache"])

    #expect(
      directory.path
        == FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("skills-cache").path)
  }

  @Test func theSeedVariableNamesTheSeedFolder() {
    let directory = MarketplaceCache.seedDirectory(
      environment: [MarketplaceCache.seedVariable: "/tmp/skills-seed"])

    #expect(directory?.path == "/tmp/skills-seed")
  }

  @Test func anAbsentSeedVariableGivesNoSeedFolder() {
    #expect(MarketplaceCache.seedDirectory(environment: [:]) == nil)
  }

  /// The path of `~/.cache/skills/marketplaces`, which §7.1 names as the
  /// fallback.
  private static var homeCachePath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/skills/marketplaces").path
  }

  // MARK: - Layout

  @Test func theMarketplaceFolderHoldsTheLayoutOfSectionSevenTwo() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let cache = fixture.cache

    #expect(cache.folder.deletingLastPathComponent().path == fixture.root.path)
    #expect(cache.repositoryDirectory.lastPathComponent == "repo.git")
    #expect(cache.refsDirectory.lastPathComponent == "refs")
    #expect(cache.snapshotsDirectory.lastPathComponent == "snapshots")
    #expect(cache.currentLink.lastPathComponent == "current")
    #expect(cache.lockFile.lastPathComponent == "lock")
    #expect(
      MarketplaceCache.stateFile(inCacheDirectory: fixture.root).lastPathComponent
        == MarketplaceState.fileName)
  }

  // MARK: - Install and swap

  @Test func installMakesCurrentNameTheNewSnapshot() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)

    try fixture.install(sha: sha)

    #expect(try fixture.cache.currentSnapshot() == fixture.cache.snapshotDirectory(forSha: sha))
    #expect(try fixture.readCurrentMarker() == sha)
  }

  @Test func theCurrentLinkIsASymlinkIntoTheSnapshotsFolder() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)

    try fixture.install(sha: sha)

    let target = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.cache.currentLink.path)
    #expect(target == "snapshots/\(sha)")
  }

  @Test func installMovesTheStagedFolderAway() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)
    let staged = try fixture.stageSnapshot(sha: sha)

    try fixture.cache.install(snapshotAt: staged, sha: sha, ref: Self.exampleRef)

    #expect(!FileManager.default.fileExists(atPath: staged.path))
  }

  @Test func installWritesTheRefFile() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)

    try fixture.install(sha: sha)

    #expect(try fixture.cache.sha(forRef: Self.exampleRef) == sha)
  }

  @Test func aSecondInstallKeepsTheFirstSnapshotForRollback() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let shas = Array(Self.exampleShas.prefix(Self.keptShaCount))

    for sha in shas {
      try fixture.install(sha: sha)
    }

    #expect(try Set(fixture.cache.installedShas()) == Set(shas))
    #expect(fixture.cache.currentSha() == shas.last)
  }

  @Test func threeInstallsLeaveTwoSnapshots() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let shas = Array(Self.exampleShas.prefix(Self.cleanupInstallCount))

    for sha in shas {
      try fixture.install(sha: sha)
    }

    #expect(try Set(fixture.cache.installedShas()) == Set(shas.suffix(Self.keptShaCount)))
    #expect(fixture.cache.currentSha() == shas.last)
  }

  @Test func cleanupKeepsASnapshotThatASharedLockHolds() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let shas = Array(Self.exampleShas.prefix(Self.cleanupInstallCount))
    let held = try #require(shas.first)
    let last = try #require(shas.last)
    for sha in shas.dropLast() {
      try fixture.install(sha: sha)
    }

    try fixture.cache.withSnapshotInUse(sha: held) { _ in
      try fixture.install(sha: last)
    }

    #expect(try Set(fixture.cache.installedShas()) == Set(shas))
  }

  @Test func aLeaseHoldsItsSnapshotUntilItIsReleased() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let held = try #require(Self.exampleShas.first)
    try fixture.install(sha: held)
    let directory = try fixture.cache.snapshotDirectory(forSha: held)
    let taken = try fixture.cache.leaseCurrentSnapshot()
    let lease = try #require(taken)

    let lockedWhileHeld = SnapshotLockProbe.isLocked(directory: directory)
    lease.releaseNow()

    #expect(lockedWhileHeld)
    #expect(!SnapshotLockProbe.isLocked(directory: directory))
  }

  @Test func aSecondReleaseOfOneLeaseDoesNothing() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let held = try #require(Self.exampleShas.first)
    try fixture.install(sha: held)
    let directory = try fixture.cache.snapshotDirectory(forSha: held)
    let taken = try fixture.cache.leaseCurrentSnapshot()
    let lease = try #require(taken)

    lease.releaseNow()
    lease.releaseNow()

    #expect(!SnapshotLockProbe.isLocked(directory: directory))
  }

  // MARK: - Staging and adopting

  @Test func aStagedSnapshotLeavesCurrentWhereItIs() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let served = try #require(Self.exampleShas.first)
    let staged = try #require(Self.exampleShas.last)
    try fixture.install(sha: served)

    try fixture.cache.withWriterLock {
      try fixture.cache.stageUnderWriterLock(
        snapshotAt: try fixture.stageSnapshot(sha: staged), sha: staged, keeping: [served])
    }

    #expect(fixture.cache.currentSha() == served)
    #expect(try Set(fixture.cache.installedShas()) == [served, staged])
  }

  @Test func adoptMakesCurrentNameAStagedSnapshot() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let served = try #require(Self.exampleShas.first)
    let staged = try #require(Self.exampleShas.last)
    try fixture.install(sha: served)
    try fixture.cache.withWriterLock {
      try fixture.cache.stageUnderWriterLock(
        snapshotAt: try fixture.stageSnapshot(sha: staged), sha: staged, keeping: [served])
    }

    try fixture.cache.adopt(snapshotSha: staged, ref: Self.exampleRef)

    #expect(fixture.cache.currentSha() == staged)
    #expect(try fixture.readCurrentMarker() == staged)
    #expect(try fixture.cache.sha(forRef: Self.exampleRef) == staged)
  }

  @Test func adoptRefusesASnapshotThatIsNotThere() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let served = try #require(Self.exampleShas.first)
    let missing = try #require(Self.exampleShas.last)
    try fixture.install(sha: served)

    #expect(throws: MarketplaceCacheError.snapshotMissing(sha: missing)) {
      try fixture.cache.adopt(snapshotSha: missing, ref: Self.exampleRef)
    }
    #expect(fixture.cache.currentSha() == served)
  }

  // MARK: - The writer lock

  @Test func aSecondWriterLockOfOneFolderIsRefusedAtOnce() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    try fixture.cache.makeFolders()

    try fixture.cache.withWriterLock {
      let refusal = #expect(throws: MarketplaceCacheError.self) {
        try fixture.cache.withWriterLock {}
      }
      #expect(refusal == .writerLockHeld(path: fixture.cache.lockFile.path))
    }
  }

  @Test func theWriterLockIsFreeAfterTheBodyReturns() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    try fixture.cache.makeFolders()
    try fixture.cache.withWriterLock {}

    let taken = try fixture.cache.withWriterLock { true }

    #expect(taken)
  }

  @Test func theAsynchronousWriterLockHoldsAcrossASuspension() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    try fixture.cache.makeFolders()

    try await fixture.cache.withWriterLock {
      await Task.yield()
      #expect(throws: MarketplaceCacheError.writerLockHeld(path: fixture.cache.lockFile.path)) {
        try fixture.cache.withWriterLock {}
      }
    }
  }

  @Test func installUnderTheWriterLockInstallsForACallerThatHoldsTheLock() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)
    try fixture.cache.makeFolders()

    try fixture.cache.withWriterLock {
      try fixture.cache.installUnderWriterLock(
        snapshotAt: try fixture.stageSnapshot(sha: sha), sha: sha, ref: Self.exampleRef)
    }

    #expect(fixture.cache.currentSha() == sha)
    #expect(try fixture.cache.sha(forRef: Self.exampleRef) == sha)
  }

  // MARK: - Lock descriptors and child processes

  @Test func aLeaseDescriptorStaysOutOfEachChildProcess() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let held = try #require(Self.exampleShas.first)
    try fixture.install(sha: held)
    let directory = try fixture.cache.snapshotDirectory(forSha: held)
    let taken = try fixture.cache.leaseCurrentSnapshot()
    let lease = try #require(taken)
    defer { lease.releaseNow() }

    let flags = OpenDescriptorProbe.descriptorFlags(ofOpensAt: directory.path)

    #expect(flags == [OpenDescriptorProbe.noInheritanceFlags])
  }

  @Test func aSnapshotInUseDescriptorStaysOutOfEachChildProcess() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let held = try #require(Self.exampleShas.first)
    try fixture.install(sha: held)

    let flags = try fixture.cache.withSnapshotInUse(sha: held) { directory in
      OpenDescriptorProbe.descriptorFlags(ofOpensAt: directory.path)
    }

    #expect(flags == [OpenDescriptorProbe.noInheritanceFlags])
  }

  @Test func theWriterLockDescriptorStaysOutOfEachChildProcess() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    try fixture.cache.makeFolders()

    let flags = try fixture.cache.withWriterLock {
      OpenDescriptorProbe.descriptorFlags(ofOpensAt: fixture.cache.lockFile.path)
    }

    #expect(flags == [OpenDescriptorProbe.noInheritanceFlags])
  }

  // MARK: - Path safety

  /// The values that must never name a snapshot folder: an empty value, the
  /// relative step, a relative step with a name after it, a value that
  /// holds a separator, an absolute path, and a hidden name. A sha is one
  /// name, so every separator is unsafe in it.
  private static let unsafeShaValues = ["", "..", "../x", "a/b", "/etc/passwd", ".hidden"]

  /// The values that must never name a ref file. A ref may hold a `/`, so
  /// each value here breaks one component rule: an empty value, the
  /// relative step alone and inside a path, an absolute path, an empty
  /// component in the middle, a trailing separator, a hidden name alone and
  /// at the front of a path, and a backslash.
  private static let unsafeRefValues = [
    "", "..", "../x", "a/../b", "/abs", "a//b", "a/", ".hidden", ".hidden/x", "a\\b",
  ]

  /// The ref names with a `/` in them that a user may write, and that the
  /// cache must take.
  private static let refsWithSeparators = ["feature/login", "refs/heads/main"]

  /// A value with the length of a commit whose letters are not hex digits.
  private static let notHexSha = String(repeating: "z", count: shaHexLength)

  /// A hex value that is too short for a commit.
  private static let shortSha = "abc"

  @Test func aValidShaNamesAFolderUnderSnapshots() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)

    let directory = try fixture.cache.snapshotDirectory(forSha: sha)

    #expect(directory.deletingLastPathComponent().path == fixture.cache.snapshotsDirectory.path)
    #expect(directory.lastPathComponent == sha)
  }

  @Test func anUppercaseShaIsACommit() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = String(repeating: "A", count: Self.shaHexLength)

    #expect(try fixture.cache.snapshotDirectory(forSha: sha).lastPathComponent == sha)
  }

  @Test(arguments: MarketplaceCacheTests.unsafeShaValues)
  func aSnapshotFolderRefusesAnUnsafeSha(value: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }

    #expect(throws: MarketplaceCacheError.unsafePathValue(kind: .sha, value: value)) {
      try fixture.cache.snapshotDirectory(forSha: value)
    }
  }

  @Test(arguments: [MarketplaceCacheTests.notHexSha, MarketplaceCacheTests.shortSha])
  func aSnapshotFolderRefusesAValueThatIsNoCommit(value: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }

    #expect(throws: MarketplaceCacheError.notACommit(value: value)) {
      try fixture.cache.snapshotDirectory(forSha: value)
    }
  }

  @Test(arguments: MarketplaceCacheTests.unsafeShaValues)
  func aSharedLockRefusesAnUnsafeSha(value: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }

    #expect(throws: MarketplaceCacheError.unsafePathValue(kind: .sha, value: value)) {
      try fixture.cache.withSnapshotInUse(sha: value) { _ in }
    }
  }

  @Test(arguments: MarketplaceCacheTests.unsafeShaValues)
  func installRefusesAnUnsafeSha(value: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let staged = try fixture.stageSnapshot(sha: try #require(Self.exampleShas.first))

    #expect(throws: MarketplaceCacheError.unsafePathValue(kind: .sha, value: value)) {
      try fixture.cache.install(snapshotAt: staged, sha: value, ref: Self.exampleRef)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.folder.path))
  }

  @Test(arguments: MarketplaceCacheTests.unsafeRefValues)
  func installRefusesAnUnsafeRef(value: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)
    let staged = try fixture.stageSnapshot(sha: sha)

    #expect(throws: MarketplaceCacheError.unsafePathValue(kind: .ref, value: value)) {
      try fixture.cache.install(snapshotAt: staged, sha: sha, ref: value)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.folder.path))
  }

  @Test(arguments: MarketplaceCacheTests.unsafeRefValues)
  func aRefLookupRefusesAnUnsafeRef(value: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }

    #expect(throws: MarketplaceCacheError.unsafePathValue(kind: .ref, value: value)) {
      try fixture.cache.sha(forRef: value)
    }
  }

  @Test func aRefLookupTakesAValidRef() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }

    #expect(try fixture.cache.sha(forRef: Self.exampleRef) == nil)
  }

  // MARK: - A ref name with a separator

  @Test(arguments: MarketplaceCacheTests.refsWithSeparators)
  func aRefWithASeparatorRoundTripsThroughAnInstall(ref: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)
    let staged = try fixture.stageSnapshot(sha: sha)

    try fixture.cache.install(snapshotAt: staged, sha: sha, ref: ref)

    #expect(try fixture.cache.sha(forRef: ref) == sha)
  }

  @Test(arguments: MarketplaceCacheTests.refsWithSeparators)
  func aRefWithASeparatorNamesAFileOneFolderDeepPerComponent(ref: String) throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let sha = try #require(Self.exampleShas.first)
    let staged = try fixture.stageSnapshot(sha: sha)
    let file = ref.split(separator: "/")
      .reduce(fixture.cache.refsDirectory) { $0.appendingPathComponent(String($1)) }

    try fixture.cache.install(snapshotAt: staged, sha: sha, ref: ref)

    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func anUnsafeSymlinkTargetNamesNoSnapshot() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let manager = FileManager.default
    try manager.createDirectory(at: fixture.cache.folder, withIntermediateDirectories: true)
    try manager.createSymbolicLink(
      atPath: fixture.cache.currentLink.path, withDestinationPath: "snapshots/..")

    #expect(fixture.cache.currentSha() == nil)
    #expect(fixture.cache.currentSnapshot() == nil)
  }

  // MARK: - Error descriptions

  /// Each cache error, with the sentence that it describes itself with.
  private static let cacheErrorDescriptions: [(error: MarketplaceCacheError, text: String)] = [
    (.cannotLock(path: "/c/lock", code: EACCES), #"Cannot lock "/c/lock": error code \#(EACCES)."#),
    (.writerLockHeld(path: "/c/lock"), #"Another writer holds the marketplace folder of "/c/lock" now."#),
    (
      .cannotSwap(path: "/c/current", code: ENOENT),
      #"Cannot put the new snapshot link "/c/current" in place: error code \#(ENOENT)."#
    ),
    (.unsafePathValue(kind: .ref, value: "../x"), #"The ref "../x" cannot go into a cache path."#),
    (.notACommit(value: "abc"), #"The sha "abc" is no commit."#),
    (.snapshotMissing(sha: "abc"), #"The cache holds no snapshot of the commit "abc"."#),
  ]

  @Test(arguments: cacheErrorDescriptions)
  func eachCacheErrorDescribesItself(error: MarketplaceCacheError, text: String) {
    #expect(error.description == text)
  }

  // MARK: - State

  @Test func aMissingStateFileGivesAnEmptyState() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }

    let state = try MarketplaceState.load(
      from: MarketplaceCache.stateFile(inCacheDirectory: fixture.root))

    #expect(state.version == MarketplaceState.currentVersion)
    #expect(state.marketplaces.isEmpty)
  }

  @Test func theStateFileRoundTrips() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let file = MarketplaceCache.stateFile(inCacheDirectory: fixture.root)
    var state = MarketplaceState()
    state.marketplaces[fixture.cache.folderName] = MarketplaceStateRecord(
      url: "git@github.com:swissarmyhammer/skills.git",
      ref: Self.exampleRef,
      currentSha: Self.exampleShas.first,
      catalogVersion: "1.2.0",
      lastChecked: Date(timeIntervalSince1970: 0),
      lastUpdated: Date(timeIntervalSince1970: 0))

    try state.save(to: file)

    #expect(try MarketplaceState.load(from: file) == state)
  }

  @Test func theStateFileRoundTripsWithAPendingSnapshot() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let file = MarketplaceCache.stateFile(inCacheDirectory: fixture.root)
    let pendingSha = try #require(Self.exampleShas.last)
    var record = MarketplaceStateRecord(url: "git@github.com:swissarmyhammer/skills.git")
    record.pending = MarketplacePendingSnapshot(
      sha: pendingSha, catalogVersion: "1.3.0", displayID: "swissarmyhammer-skills")
    record.unpinned = true
    var state = MarketplaceState()
    state.marketplaces[fixture.cache.folderName] = record

    try state.save(to: file)

    #expect(try MarketplaceState.load(from: file) == state)
  }

  @Test func aStateFileWithEveryFieldDecodesEachField() throws {
    let sha = try #require(Self.exampleShas.first)
    let pendingSha = try #require(Self.exampleShas.last)
    let text = """
      {
        "version": 1,
        "marketplaces": {
          "swissarmyhammer-skills-1a2b3c4d": {
            "url": "git@github.com:swissarmyhammer/skills.git",
            "ref": "main", "pinnedSha": null, "unpinned": true,
            "pending": { "sha": "\(pendingSha)", "catalogVersion": "1.3.0", "displayID": "skills-next" },
            "currentSha": "\(sha)", "catalogVersion": "1.2.0", "displayID": "swissarmyhammer-skills",
            "lastChecked": "2026-09-14T19:55:43Z", "lastUpdated": "2026-09-12T08:10:00Z",
            "lastError": null
          }
        }
      }
      """

    let state = try MarketplaceState.decode(from: Data(text.utf8))

    let record = try #require(state.marketplaces["swissarmyhammer-skills-1a2b3c4d"])
    #expect(state.version == MarketplaceState.currentVersion)
    #expect(record.url == "git@github.com:swissarmyhammer/skills.git")
    #expect(record.ref == Self.exampleRef)
    #expect(record.pinnedSha == nil)
    #expect(record.unpinned == true)
    #expect(record.pending?.sha == pendingSha)
    #expect(record.pending?.catalogVersion == "1.3.0")
    #expect(record.pending?.displayID == "skills-next")
    #expect(record.currentSha == sha)
    #expect(record.catalogVersion == "1.2.0")
    #expect(record.displayID == "swissarmyhammer-skills")
    #expect(record.lastChecked == Date(timeIntervalSince1970: Self.lastCheckedEpochSeconds))
    #expect(record.lastUpdated == Date(timeIntervalSince1970: Self.lastUpdatedEpochSeconds))
    #expect(record.lastError == nil)
  }

  /// The seconds since 1970 of `2026-09-14T19:55:43Z`, the `lastChecked`
  /// value of the full state file.
  private static let lastCheckedEpochSeconds: TimeInterval = 1_789_415_743

  /// The seconds since 1970 of `2026-09-12T08:10:00Z`, the `lastUpdated`
  /// value of the full state file.
  private static let lastUpdatedEpochSeconds: TimeInterval = 1_789_200_600

  @Test func aStateFileWithNoFieldsDecodesToAnEmptyState() throws {
    let state = try MarketplaceState.decode(from: Data("{}".utf8))

    #expect(state == MarketplaceState())
  }

  // MARK: - A reader during installs

  @Test func aReaderResolvesACompleteSnapshotDuringRepeatedInstalls() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let shas = Self.exampleShas
    try fixture.install(sha: try #require(shas.first))
    let reads = shas.count

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for sha in shas.dropFirst() {
          try fixture.install(sha: sha)
        }
      }
      #expect(try await fixture.countCompleteReads(times: reads) == reads)
      try await group.waitForAll()
    }
  }
}
