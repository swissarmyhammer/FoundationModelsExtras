import CryptoKit
import Foundation

/// The identity rules of a marketplace (marketplace.md §5.3).
///
/// Before a fetch, the store knows only the source. Thus validation and the
/// cache folder name use the **pre-fetch key**: the alias, else the last path
/// component of the repository without `.git`. After a fetch, the catalog
/// `name` becomes the display id. The store records that.
internal enum MarketplaceIdentity {
  /// The number of hex digits of the URL hash in a cache folder name.
  static let cacheHashPrefixLength = 8

  /// The characters that a pre-fetch key cannot have, because the key is
  /// one folder name.
  private static let forbiddenKeyCharacters: Set<Character> = ["/", "\0"]

  /// The format of one byte as two lowercase hex digits.
  private static let hexByteFormat = "%02x"

  /// Gives the pre-fetch key of `source`.
  ///
  /// The call parses the location of the source first. Thus a source with a
  /// bad URL gives no key, also when it has an alias.
  ///
  /// - Parameter source: The source.
  /// - Returns: The alias, else the repository name without `.git`.
  /// - Throws: ``MarketplaceSourceError`` when the URL is bad, or
  ///   ``MarketplaceSourceError/unusableKey(_:)`` when the key is not one
  ///   folder name.
  static func preFetchKey(for source: MarketplaceSource) throws -> String {
    let location = try MarketplaceLocation(source: source)
    let key = source.alias ?? location.repositoryName
    guard !key.isEmpty, !key.contains(where: forbiddenKeyCharacters.contains) else {
      throw MarketplaceSourceError.unusableKey(key)
    }
    return key
  }

  /// Gives the name of the cache folder of one marketplace.
  ///
  /// - Parameters:
  ///   - key: The pre-fetch key.
  ///   - normalizedURL: The normalized URL of the location.
  /// - Returns: `<key>-<first 8 hex of SHA-256(normalizedURL)>`. Thus a
  ///   changed URL never uses a stale cache.
  static func cacheFolderName(key: String, normalizedURL: String) -> String {
    let digest = SHA256.hash(data: Data(normalizedURL.utf8))
    let hex = digest.map { String(format: hexByteFormat, $0) }.joined()
    return "\(key)-\(hex.prefix(cacheHashPrefixLength))"
  }

  /// Validates a source list before any fetch.
  ///
  /// - Parameter sources: The sources, in list order.
  /// - Returns: One error diagnostic for each source that gives no
  ///   pre-fetch key, then one error diagnostic for each pre-fetch key that
  ///   more than one source has. An empty result means that the list is
  ///   valid.
  static func validate(_ sources: [MarketplaceSource]) -> [MarketplaceDiagnostic] {
    let results = sources.map { source in (source: source, key: Result { try preFetchKey(for: source) }) }
    let unusable: [MarketplaceDiagnostic] = results.compactMap { entry in
      guard case .failure(let error) = entry.key else {
        return nil
      }
      return unusableSourceDiagnostic(for: entry.source, error: error)
    }
    let keyed: [(key: String, url: String)] = results.compactMap { entry in
      guard case .success(let key) = entry.key else {
        return nil
      }
      return (key, entry.source.url)
    }
    return unusable + duplicateKeyDiagnostics(keyed)
  }

  /// Makes the diagnostic for a source that gives no pre-fetch key.
  ///
  /// - Parameters:
  ///   - source: The source.
  ///   - error: Why the source gives no key.
  /// - Returns: An error diagnostic about the alias of the source, if it has
  ///   one.
  private static func unusableSourceDiagnostic(for source: MarketplaceSource, error: any Error) -> MarketplaceDiagnostic {
    MarketplaceDiagnostic(
      severity: .error,
      marketplaceID: source.alias,
      message: #"The source "\#(source.url)" is not usable: \#(error)"#)
  }

  /// Makes one diagnostic for each pre-fetch key that more than one source
  /// has, in the order of the first source with that key.
  ///
  /// - Parameter keyed: The key and the URL of each usable source, in list
  ///   order.
  /// - Returns: The error diagnostics.
  private static func duplicateKeyDiagnostics(_ keyed: [(key: String, url: String)]) -> [MarketplaceDiagnostic] {
    Dictionary(grouping: keyed.enumerated(), by: \.element.key).values
      .filter { $0.count > 1 }
      .sorted { $0[0].offset < $1[0].offset }
      .map { group in
        let key = group[0].element.key
        let urls = group.lazy.map { #""\#($0.element.url)""# }.joined(separator: ", ")
        return MarketplaceDiagnostic(
          severity: .error,
          marketplaceID: key,
          message:
            #"More than one source has the pre-fetch key "\#(key)": \#(urls). The store does not merge them. Set a different alias on each source."#
        )
      }
  }
}
