import Foundation

/// What a host lets a ``MarketplaceStore`` do (marketplace.md §6.7, §7.3
/// step 4, and §8.2).
///
/// Every field is a count or a host value. The package names no interval, no
/// jitter, and no age limit of its own: a check runs at `start()` and on
/// request, a periodic check runs only when the host gives
/// ``checkInterval``, a fetch stops early only when the host gives
/// ``fetchTimeout``, and cleanup counts snapshots (decision 13).
///
/// ```swift
/// let policy = MarketplacePolicy(credentials: { url in
///   url.host == "git.example.com" ? MarketplaceCredential(username: "reader", token: token) : nil
/// })
/// ```
public struct MarketplacePolicy: Sendable {
  /// The name of the environment variable that stops every automatic
  /// update (marketplace.md §8.3).
  public static let automaticUpdateVariable = "SKILLS_MARKETPLACE_AUTOUPDATE"

  /// The value of ``automaticUpdateVariable`` that stops every automatic
  /// update.
  private static let automaticUpdateOffValue = "0"

  /// Why a policy refuses one source (marketplace.md §6.7).
  internal enum SourceRefusal: Sendable, Hashable {
    /// One entry of ``blockedSources`` names the source.
    case blocked(SourcePattern)

    /// ``allowedSources`` is a list, and no entry of it names the source.
    case notAllowed
  }

  /// When a new snapshot becomes the one that the consumer reads
  /// (marketplace.md §8.4).
  public enum ApplyUpdates: Sendable, Hashable {
    /// The install makes `current` name the new snapshot at once, thus
    /// the consumer rebuilds its catalog while the process runs. This is
    /// the default: the package hot-reloads by design.
    case immediately

    /// The install materializes the new snapshot and records it as
    /// pending. The next ``MarketplaceStore/start()`` makes `current`
    /// name it, thus a running session keeps the catalog it started
    /// with.
    ///
    /// The pending record lives in `state.json`, thus it is a flag on the
    /// disk and no timer, and it survives a restart.
    case nextLaunch
  }

  /// The size and the file count that one snapshot may reach.
  public var snapshotLimits: SnapshotLimits

  /// The sources that the host permits, or `nil` for every source
  /// (marketplace.md §6.7).
  ///
  /// With a list, a source must match one entry of it. An empty list thus
  /// refuses every source. ``blockedSources`` wins over this list.
  public var allowedSources: [SourcePattern]?

  /// The sources that the host refuses (marketplace.md §6.7).
  ///
  /// A source that matches one entry here gets no layer, whatever
  /// ``allowedSources`` says.
  public var blockedSources: [SourcePattern]

  /// Gives the credential of a private HTTPS source, or `nil` for a host
  /// that has none.
  ///
  /// The store hands the provider to the git transport. The transport asks
  /// it only for an HTTPS source, and it sends the credential only to the
  /// origin of that source. The credential never becomes part of a URL that
  /// the store writes or shows.
  public var credentials: (@Sendable (URL) async -> MarketplaceCredential?)?

  /// How long the store waits between two periodic checks, or `nil` for no
  /// periodic check.
  ///
  /// The package has no interval of its own. With `nil`, the store checks
  /// at `start()` and on request, and never again by itself. A long-running
  /// host, such as an agent server or an editor, gives a value here; a
  /// short command-line run does not need one (marketplace.md §8.2).
  public var checkInterval: Duration?

  /// Whether a check that finds a new commit also installs it.
  ///
  /// With `false`, the store publishes
  /// ``MarketplaceEvent/updateAvailable(id:from:to:)`` and fetches nothing.
  /// The host or the command line then asks for the update
  /// (marketplace.md §8.3).
  public var autoUpdate: Bool

  /// Whether the store only reports, and never installs.
  ///
  /// With `true`, every update request becomes a check: the store reads the
  /// remote head, publishes what it found, and downloads no content. This
  /// is the dry run of marketplace.md §8.3.
  public var checkOnly: Bool

  /// When a new snapshot becomes the one that the consumer reads
  /// (marketplace.md §8.4).
  ///
  /// The default is ``ApplyUpdates/immediately``: the package hot-reloads
  /// by design. A host that wants a stable session sets
  /// ``ApplyUpdates/nextLaunch``.
  public var applyUpdates: ApplyUpdates

  /// How long one fetch may take, or `nil` for no limit.
  ///
  /// The package has no timeout of its own. With a value, a fetch that
  /// takes longer is cancelled, and the store publishes
  /// ``MarketplaceEvent/failed(id:error:keptVersion:)`` and keeps the
  /// snapshot that `current` names (marketplace.md §5.1).
  public var fetchTimeout: Duration?

  /// Creates a policy.
  ///
  /// - Parameters:
  ///   - snapshotLimits: The size and the file count that one snapshot may
  ///     reach. The default is ``SnapshotLimits/init(maxBytes:maxFiles:)``
  ///     with its own defaults.
  ///   - allowedSources: The sources that the host permits. The default is
  ///     `nil`: every source.
  ///   - blockedSources: The sources that the host refuses. The default is
  ///     an empty list: no refused source.
  ///   - credentials: Gives the credential of a private HTTPS source. The
  ///     default is `nil`: no credential.
  ///   - checkInterval: How long the store waits between two periodic
  ///     checks. The default is `nil`: no periodic check.
  ///   - autoUpdate: Whether a check that finds a new commit also installs
  ///     it. The default is `true`.
  ///   - checkOnly: Whether the store only reports. The default is `false`.
  ///   - applyUpdates: When a new snapshot becomes the one that the
  ///     consumer reads. The default is ``ApplyUpdates/immediately``.
  ///   - fetchTimeout: How long one fetch may take. The default is `nil`:
  ///     no limit.
  ///   - environment: The environment to read. `SKILLS_MARKETPLACE_AUTOUPDATE=0`
  ///     there has the same effect as `autoUpdate: false`. The default is
  ///     the environment of this process.
  public init(
    snapshotLimits: SnapshotLimits = SnapshotLimits(),
    allowedSources: [SourcePattern]? = nil,
    blockedSources: [SourcePattern] = [],
    credentials: (@Sendable (URL) async -> MarketplaceCredential?)? = nil,
    checkInterval: Duration? = nil,
    autoUpdate: Bool = true,
    checkOnly: Bool = false,
    applyUpdates: ApplyUpdates = .immediately,
    fetchTimeout: Duration? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.snapshotLimits = snapshotLimits
    self.allowedSources = allowedSources
    self.blockedSources = blockedSources
    self.credentials = credentials
    self.checkInterval = checkInterval
    self.autoUpdate = autoUpdate && Self.automaticUpdatesAllowed(environment: environment)
    self.checkOnly = checkOnly
    self.applyUpdates = applyUpdates
    self.fetchTimeout = fetchTimeout
  }

  /// Whether this policy refuses one source (marketplace.md §6.7 and §10
  /// item 2).
  ///
  /// The call is a pure function of the policy and of the URL: it reads no
  /// file and opens no connection. Thus the store runs it before it makes
  /// a cache folder or reaches a remote. ``blockedSources`` wins over
  /// ``allowedSources``.
  ///
  /// - Parameter normalizedURL: ``MarketplaceLocation/normalizedURL`` of
  ///   the source.
  /// - Returns: Why the policy refuses the source, or `nil` when it lets
  ///   the source load.
  internal func refusal(forNormalizedURL normalizedURL: String) -> SourceRefusal? {
    if let blocked = blockedSources.first(where: { $0.matches(normalizedURL: normalizedURL) }) {
      return .blocked(blocked)
    }
    guard let allowedSources else {
      return nil
    }
    let allowed = allowedSources.contains { $0.matches(normalizedURL: normalizedURL) }
    return allowed ? nil : .notAllowed
  }

  /// Whether an environment lets the store update by itself
  /// (marketplace.md §8.3).
  ///
  /// The call is a pure function of the environment, thus a test gives its
  /// own.
  ///
  /// - Parameter environment: The environment to read. The default is the
  ///   environment of this process.
  /// - Returns: `false` when ``automaticUpdateVariable`` is `0`, else
  ///   `true`.
  public static func automaticUpdatesAllowed(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment[automaticUpdateVariable] != automaticUpdateOffValue
  }
}
