import Foundation
import MarketplaceFixtures
import Testing

@testable import Marketplace

/// Tests for the source allowlist and the source blocklist of
/// ``MarketplacePolicy`` over a store (marketplace.md §6.7 and §10 item 2).
///
/// The store runs both lists before any network work and before any disk
/// work. Thus each test counts the calls of ``RecordingGitTransport`` and
/// looks for the cache folder of the refused source.
@Suite("Marketplace policy")
struct MarketplacePolicyTests {
  /// The body of the skill of every fixture commit.
  private static let skillBody = "alpha body"

  /// The normalized URL of one source.
  ///
  /// - Parameter source: The source to parse.
  /// - Returns: The normalized URL.
  /// - Throws: ``MarketplaceSourceError`` when the URL is no §5.1 form.
  private static func normalizedURL(of source: MarketplaceSource) throws -> String {
    try MarketplaceLocation(source: source).normalizedURL
  }

  /// The cache folder that one source would get.
  ///
  /// - Parameters:
  ///   - source: The source.
  ///   - root: The cache directory of the store.
  /// - Returns: `<root>/<key>-<hash>`, which a refused source never makes.
  /// - Throws: ``MarketplaceSourceError`` when the URL is no §5.1 form.
  private static func cacheFolder(of source: MarketplaceSource, inDirectory root: URL) throws -> URL {
    let name = MarketplaceIdentity.cacheFolderName(
      key: try MarketplaceIdentity.preFetchKey(for: source), normalizedURL: try normalizedURL(of: source))
    return root.appendingPathComponent(name, isDirectory: true)
  }

  /// Whether one diagnostic list holds an error that names a source and a
  /// pattern.
  ///
  /// - Parameters:
  ///   - diagnostics: The diagnostics of the store.
  ///   - url: The source URL, as the host wrote it.
  ///   - pattern: The pattern that refused the source, or `nil` when the
  ///     allowlist refused it with no one pattern.
  /// - Returns: `true` when one error diagnostic names both.
  private static func holdsRefusal(
    in diagnostics: [MarketplaceDiagnostic], ofURL url: String, pattern: SourcePattern?
  ) -> Bool {
    diagnostics.contains { diagnostic in
      diagnostic.severity == .error && diagnostic.message.contains(url)
        && (pattern.map { diagnostic.message.contains(String(describing: $0)) } ?? true)
    }
  }

  // MARK: - The blocklist

  @Test func aBlockedSourceMakesNoTransportCallAndGetsNoLayer() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: MarketplaceTestSupport.skillTree(body: Self.skillBody))
    let source = MarketplaceSource(fixture.url)
    let blocked = SourcePattern.exact(try Self.normalizedURL(of: source))
    let transport = RecordingGitTransport()
    let cache = try MarketplaceStoreFixture(
      sources: [source], policy: MarketplacePolicy(blockedSources: [blocked]), transport: transport)

    await cache.store.start()

    #expect(await transport.remoteHeadCount == 0)
    #expect(await transport.fetchCount == 0)
    #expect(cache.store.marketplaceLayers().isEmpty)
    let folder = try Self.cacheFolder(of: source, inDirectory: cache.cacheDirectory)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(Self.holdsRefusal(in: cache.store.diagnostics, ofURL: fixture.url, pattern: blocked))
  }

  @Test func anOwnerPatternInTheBlocklistRefusesEveryRepositoryOfThatOwner() async throws {
    let transport = RecordingGitTransport()
    let policy = MarketplacePolicy(blockedSources: [.owner(host: "github.com", owner: "acme")])
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource("github:acme/skills")], policy: policy, transport: transport)

    await cache.store.start()

    #expect(await transport.remoteHeadCount == 0)
    #expect(cache.store.marketplaceLayers().isEmpty)
  }

  // MARK: - The allowlist

  @Test func anEmptyAllowlistRefusesEverySource() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: MarketplaceTestSupport.skillTree(body: Self.skillBody))
    let transport = RecordingGitTransport()
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], policy: MarketplacePolicy(allowedSources: []),
      transport: transport)

    await cache.store.start()

    #expect(await transport.remoteHeadCount == 0)
    #expect(await transport.fetchCount == 0)
    #expect(cache.store.marketplaceLayers().isEmpty)
    #expect(Self.holdsRefusal(in: cache.store.diagnostics, ofURL: fixture.url, pattern: nil))
  }

  @Test func anAllowlistThatNoSourceMatchesRefusesTheSource() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: MarketplaceTestSupport.skillTree(body: Self.skillBody))
    let transport = RecordingGitTransport()
    let policy = MarketplacePolicy(allowedSources: [.owner(host: "github.com", owner: "acme")])
    let cache = try MarketplaceStoreFixture(
      sources: [MarketplaceSource(fixture.url)], policy: policy, transport: transport)

    await cache.store.start()

    #expect(await transport.remoteHeadCount == 0)
    #expect(cache.store.marketplaceLayers().isEmpty)
  }

  @Test func anAllowedSourceStillSyncs() async throws {
    let fixture = try GitFixtureRepository()
    let head = try fixture.commit(files: MarketplaceTestSupport.skillTree(body: Self.skillBody))
    let source = MarketplaceSource(fixture.url)
    let policy = MarketplacePolicy(allowedSources: [.exact(try Self.normalizedURL(of: source))])
    let cache = try MarketplaceStoreFixture(sources: [source], policy: policy)

    await cache.store.start()

    let layer = try #require(cache.store.marketplaceLayers().first)
    #expect(layer.provenance.sha == head)
    #expect(try MarketplaceTestSupport.skillBody(inLayerRoot: layer.layer.root).contains(Self.skillBody))
  }

  // MARK: - Both lists

  @Test func theBlocklistWinsOverTheAllowlist() async throws {
    let fixture = try GitFixtureRepository()
    try fixture.commit(files: MarketplaceTestSupport.skillTree(body: Self.skillBody))
    let source = MarketplaceSource(fixture.url)
    let pattern = SourcePattern.exact(try Self.normalizedURL(of: source))
    let transport = RecordingGitTransport()
    let cache = try MarketplaceStoreFixture(
      sources: [source], policy: MarketplacePolicy(allowedSources: [pattern], blockedSources: [pattern]),
      transport: transport)

    await cache.store.start()

    #expect(await transport.remoteHeadCount == 0)
    #expect(cache.store.marketplaceLayers().isEmpty)
    #expect(Self.holdsRefusal(in: cache.store.diagnostics, ofURL: fixture.url, pattern: pattern))
  }

  @Test func aPolicyWithNoListAllowsEverySource() async throws {
    let fixture = try GitFixtureRepository()
    let head = try fixture.commit(files: MarketplaceTestSupport.skillTree(body: Self.skillBody))
    let cache = try MarketplaceStoreFixture(sources: [MarketplaceSource(fixture.url)])

    await cache.store.start()

    #expect(cache.store.marketplaceLayers().first?.provenance.sha == head)
  }
}
