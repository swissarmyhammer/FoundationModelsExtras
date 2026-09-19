import FixtureSupport
import Foundation
import Marketplace

/// One ``MarketplaceStore`` over a temporary cache, plus an empty local layer
/// root that a consumer test puts above the marketplace layers.
///
/// The fixture removes every folder that it made when it is released, thus a
/// store test leaves nothing behind. It is public so that the store tests of
/// `FoundationModelsSkills` build a store the same way.
public final class MarketplaceStoreFixture {
  /// The layout that every fixture repository of this package follows:
  /// `SKILL.md` marks an entry folder.
  public static let skillsLayout = MarketplaceLayout(documentName: "SKILL.md")

  /// The cache directory of the store.
  public let cacheDirectory: URL

  /// The root of one empty local layer, for a consumer test that puts a
  /// local layer above the marketplace layers.
  public let localRoot: URL

  /// The store under test.
  public let store: MarketplaceStore

  /// Whether the fixture made ``cacheDirectory`` and thus removes it.
  private let ownsCacheDirectory: Bool

  /// Makes a store over a temporary cache.
  ///
  /// - Parameters:
  ///   - sources: The marketplace sources, in list order.
  ///   - layout: The shape of a marketplace tree. The default is
  ///     ``skillsLayout``.
  ///   - cacheDirectory: The cache directory to share with another store,
  ///     or `nil` for a new temporary one. The default is `nil`.
  ///   - policy: The policy of the store. The default is
  ///     `MarketplacePolicy()`.
  ///   - transport: The git transport, or `nil` for the real
  ///     ``LibGit2Transport``. The default is `nil`.
  ///   - clock: The clock of the periodic check and of the fetch timeout,
  ///     or `nil` for the `ContinuousClock` of the store. The default is
  ///     `nil`.
  ///   - environment: The environment of the store, which names the
  ///     read-only seed folder. The default is no variable at all.
  /// - Throws: The error of a folder write.
  public init(
    sources: [MarketplaceSource], layout: MarketplaceLayout = skillsLayout, cacheDirectory: URL? = nil,
    policy: MarketplacePolicy = MarketplacePolicy(), transport: (any GitTransport)? = nil,
    clock: (any Clock<Duration>)? = nil, environment: [String: String] = [:]
  ) throws {
    ownsCacheDirectory = cacheDirectory == nil
    self.cacheDirectory = try cacheDirectory ?? TemporaryDirectory.make()
    localRoot = try TemporaryDirectory.make()
    store = MarketplaceStore(
      sources: sources, layout: layout, cacheDirectory: self.cacheDirectory, policy: policy,
      transport: transport ?? LibGit2Transport(), clock: clock ?? ContinuousClock(),
      environment: environment)
  }

  deinit {
    try? FileManager.default.removeItem(at: localRoot)
    if ownsCacheDirectory {
      try? FileManager.default.removeItem(at: cacheDirectory)
    }
  }
}
