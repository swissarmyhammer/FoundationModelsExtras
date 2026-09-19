import Foundation

/// Why ``MarketplaceConfig`` cannot read one `marketplaces.yaml` file
/// (marketplace.md §6.3).
///
/// The error names the file, so a host can tell the user which file to
/// correct.
public struct MarketplaceConfigError: Error, CustomStringConvertible {
  /// The file that cannot be read or decoded.
  public var file: URL

  /// The error of the file read or of the YAML decoder.
  public var underlyingError: any Error

  /// Creates an error for one configuration file.
  ///
  /// - Parameters:
  ///   - file: The file that cannot be read or decoded.
  ///   - underlyingError: The error of the file read or of the YAML
  ///     decoder.
  public init(file: URL, underlyingError: any Error) {
    self.file = file
    self.underlyingError = underlyingError
  }

  /// A sentence that names the file and the problem.
  public var description: String {
    #"Cannot read the marketplace configuration "\#(file.path)": \#(underlyingError)"#
  }
}
