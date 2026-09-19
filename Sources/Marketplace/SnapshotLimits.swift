/// The host policy limits of one snapshot write (marketplace.md §7.3 step 4).
///
/// The limits are counts, not times. ``MarketplacePolicy`` carries them, so a
/// host that wants a different size or file count sets them there.
public struct SnapshotLimits: Sendable, Hashable {
  /// The number of bytes in one kibibyte.
  private static let bytesInOneKibibyte = 1024

  /// The number of kibibytes in one mebibyte.
  private static let kibibytesInOneMebibyte = 1024

  /// The number of bytes in one mebibyte.
  private static let bytesInOneMebibyte = bytesInOneKibibyte * kibibytesInOneMebibyte

  /// The number of mebibytes that one snapshot may reach when the host names
  /// none.
  private static let defaultMaximumMebibytes = 64

  /// The size that one snapshot may reach when the host names none:
  /// 64 mebibytes.
  public static let defaultMaximumBytes = defaultMaximumMebibytes * bytesInOneMebibyte

  /// The number of files that one snapshot may hold when the host names
  /// none.
  public static let defaultMaximumFiles = 5_000

  /// The largest number of bytes that one snapshot holds, over every file.
  public let maxBytes: Int

  /// The largest number of files that one snapshot holds.
  public let maxFiles: Int

  /// Creates the limits of one snapshot write.
  ///
  /// - Parameters:
  ///   - maxBytes: The largest number of bytes that one snapshot holds. The
  ///     default is ``defaultMaximumBytes``.
  ///   - maxFiles: The largest number of files that one snapshot holds. The
  ///     default is ``defaultMaximumFiles``.
  public init(maxBytes: Int = defaultMaximumBytes, maxFiles: Int = defaultMaximumFiles) {
    self.maxBytes = maxBytes
    self.maxFiles = maxFiles
  }
}
