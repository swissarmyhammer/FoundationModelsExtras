import FixtureSupport
import Foundation
import MarketplaceFixtures
import Testing

@testable import Marketplace

/// Tests for the two sources of ``MarketplaceStore`` that need no network
/// (marketplace.md §5.1, §7.4, and §7.5): a `file://` folder that the store
/// reads directly and that a consumer watches as a local layer, and the
/// read-only seed folder that serves a git marketplace when the cache holds
/// none.
@Suite("Marketplace local source")
struct MarketplaceLocalSourceTests {
  /// The `path` field of a source that names a folder other than `skills`.
  private static let libraryFolderName = "library"

  // MARK: - The file:// layer (§5.1)

  @Test func aLocalFolderSourceServesItsSkillsWithNoCacheFolderAndNoNetwork() async throws {
    let folder = try Self.makeLocalMarketplace(body: "local folder body")
    defer { try? FileManager.default.removeItem(at: folder) }
    let transport = RecordingGitTransport()
    let fixture = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(Self.url(ofFolder: folder))], transport: transport)

    await fixture.store.start()

    let layer = try #require(fixture.store.marketplaceLayers().first)
    #expect(
      layer.layer.root.canonicalDirectory
        == folder.appendingPathComponent(MarketplaceTestSupport.skillsFolderName, isDirectory: true))
    #expect(layer.isWatchable, "a folder on this computer is watched as a local layer")
    #expect(try MarketplaceTestSupport.skillBody(inLayerRoot: layer.layer.root).contains("local folder body"))
    #expect(await transport.remoteHeadCount == 0)
    #expect(await transport.fetchCount == 0)
    #expect(try Self.entryCount(ofDirectory: fixture.cacheDirectory) == 0)
  }

  @Test func aLocalFolderSourceGivesItsLayerBeforeStart() throws {
    let folder = try Self.makeLocalMarketplace(body: "local folder body")
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = try MarketplaceStoreFixture(sources: [MarketplaceSource(Self.url(ofFolder: folder))])

    let layer = try #require(fixture.store.marketplaceLayers().first)

    #expect(layer.layer.source == .marketplace)
    #expect(layer.provenance.url == Self.url(ofFolder: folder))
    #expect(layer.provenance.sha == nil)
  }

  @Test func aPathFieldNamesTheFolderOfTheLayerUnderTheLocalRoot() async throws {
    let folder = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: folder) }
    let inner = folder.appendingPathComponent(Self.libraryFolderName, isDirectory: true)
    try MarketplaceTestSupport.writeSkillFolder(
      named: MarketplaceTestSupport.fixtureSkillID, in: inner, body: "library body")
    let fixture = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(Self.url(ofFolder: folder), path: Self.libraryFolderName)])

    let layer = try #require(fixture.store.marketplaceLayers().first)
    #expect(layer.layer.root.canonicalDirectory == inner)
    #expect(try MarketplaceTestSupport.skillBody(inLayerRoot: layer.layer.root).contains("library body"))
  }

  @Test func aSelectionOtherThanAllOverALocalFolderGivesADiagnosticAndIsIgnored() async throws {
    let folder = try Self.makeLocalMarketplace(body: "local folder body")
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = MarketplaceSource(Self.url(ofFolder: folder), select: .skills(["other"]))
    let fixture = try MarketplaceStoreFixture(sources: [source])

    let layer = try #require(fixture.store.marketplaceLayers().first)
    #expect(try MarketplaceTestSupport.skillBody(inLayerRoot: layer.layer.root).contains("local folder body"))
    #expect(fixture.store.diagnostics.contains { $0.severity == .warning && $0.message.contains("select") })
  }

  @Test func aPathThatLeavesTheLocalFolderGivesNoLayerAndAnError() throws {
    let folder = try Self.makeLocalMarketplace(body: "local folder body")
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = MarketplaceSource(Self.url(ofFolder: folder), path: "../outside")
    let fixture = try MarketplaceStoreFixture(sources: [source])

    #expect(fixture.store.marketplaceLayers().isEmpty)
    #expect(fixture.store.diagnostics.contains { $0.severity == .error && $0.message.contains("relative path") })
  }

  // MARK: - The watched file:// root (§7.4)

  @Test func aCacheBackedMarketplaceLayerIsNotWatched() throws {
    let repository = try GitFixtureRepository()
    try repository.commit(files: MarketplaceTestSupport.skillTree(body: "git body"))
    let fixture = try MarketplaceStoreFixture(sources: [MarketplaceSource(repository.url)])

    let layer = try #require(fixture.store.marketplaceLayers().first)
    #expect(
      !layer.isWatchable,
      "a snapshot swap sends no reliable event, thus the cache root reloads on layerUpdates only")
  }

  // MARK: - The read-only seed folder (§7.5)

  @Test func aSeedEntryServesTheLayerWhenTheCacheHasNone() async throws {
    let seed = try await SeedFixture()

    let layer = try #require(seed.store.marketplaceLayers().first)
    #expect(layer.provenance.sha == seed.seededSha)
    #expect(layer.layer.root.path.hasPrefix(seed.seedDirectory.path))
    #expect(try MarketplaceTestSupport.skillBody(inLayerRoot: layer.layer.root).contains("seed body"))
  }

  @Test func anUpdateOfASeedEntryWritesNothingAndGivesADiagnostic() async throws {
    let seed = try await SeedFixture()
    try seed.repository.commit(files: MarketplaceTestSupport.skillTree(body: "seed body v2"))

    let events = await seed.store.update()

    #expect(events.isEmpty)
    #expect(seed.store.marketplaceLayers().first?.provenance.sha == seed.seededSha)
    #expect(try seed.installedSeedShas() == [seed.seededSha])
    #expect(try Self.entryCount(ofDirectory: seed.fixture.cacheDirectory) == 0)
    #expect(seed.store.diagnostics.contains { $0.severity == .advisory && $0.message.contains("seed") })
  }

  // MARK: - Support

  /// One store over a git source that only the seed folder serves.
  ///
  /// The fixture installs one commit into a seed folder with a store of its
  /// own, and then builds the store under test over an empty cache whose
  /// environment names that seed folder.
  private struct SeedFixture {
    /// The repository that both stores read.
    let repository: GitFixtureRepository

    /// The read-only seed folder, in the cache layout.
    let seedDirectory: URL

    /// The commit that the seed folder holds.
    let seededSha: String

    /// The store under test, with its own empty cache.
    let fixture: MarketplaceStoreFixture

    /// The store under test.
    var store: MarketplaceStore {
      fixture.store
    }

    /// Seeds the folder and builds the store under test.
    ///
    /// - Throws: The error of a folder write, of the repository, or of the
    ///   install.
    init() async throws {
      repository = try GitFixtureRepository()
      seededSha = try repository.commit(files: MarketplaceTestSupport.skillTree(body: "seed body"))
      seedDirectory = try TemporaryDirectory.make()
      let source = MarketplaceSource(repository.url)
      let seeding = try MarketplaceStoreFixture(sources: [source], cacheDirectory: seedDirectory)
      await seeding.store.start()
      fixture = try MarketplaceStoreFixture(
        sources: [source], environment: [MarketplaceCache.seedVariable: seedDirectory.path])
    }

    /// The commits that the seed folder holds.
    ///
    /// - Returns: The commits, in order.
    /// - Throws: The error of the folder read.
    func installedSeedShas() throws -> [String] {
      let marketplaces = try FileManager.default.contentsOfDirectory(
        at: seedDirectory, includingPropertiesForKeys: nil)
      return try marketplaces.flatMap { folder -> [String] in
        let snapshots = folder.appendingPathComponent("snapshots", isDirectory: true)
        return FileManager.default.fileExists(atPath: snapshots.path)
          ? try FileManager.default.contentsOfDirectory(atPath: snapshots.path).sorted() : []
      }
    }
  }

  /// Makes a folder in the layout of a local marketplace: one skill under
  /// `skills`.
  ///
  /// - Parameter body: The body of the skill.
  /// - Returns: The new folder.
  /// - Throws: The error of a folder or file write.
  private static func makeLocalMarketplace(body: String) throws -> URL {
    let folder = try TemporaryDirectory.make()
    try MarketplaceTestSupport.writeSkillFolder(
      named: MarketplaceTestSupport.fixtureSkillID,
      in: folder.appendingPathComponent(MarketplaceTestSupport.skillsFolderName, isDirectory: true), body: body)
    return folder
  }

  /// The `file://` URL of a folder.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The URL, with no `.git` suffix, thus a local folder source.
  private static func url(ofFolder folder: URL) -> String {
    "file://\(folder.path)"
  }

  /// How many items a directory holds.
  ///
  /// - Parameter directory: The directory to read.
  /// - Returns: The number of items, or zero when the directory is not
  ///   there.
  /// - Throws: The error of the folder read.
  private static func entryCount(ofDirectory directory: URL) throws -> Int {
    FileManager.default.fileExists(atPath: directory.path)
      ? try FileManager.default.contentsOfDirectory(atPath: directory.path).count : 0
  }
}
