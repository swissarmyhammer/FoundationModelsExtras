/// One entry of the `dependencies` list of a target of the manifest.
///
/// ``PackageManifest/dependencies(ofTarget:in:)`` gives these entries. The
/// manifest suites of more than one test target compare them with the
/// dependencies that they expect.
public enum TargetDependency: Hashable, Sendable, CustomStringConvertible {
  /// A dependency that the manifest names with a string only: a target of the
  /// package, or a product with the name of its package.
  case byName(String)

  /// A `.product(name:package:)` dependency.
  case product(name: String, package: String)

  /// An entry of a form that the read does not know, as the manifest writes
  /// it. No expected dependency is equal to it, thus a check that compares
  /// entries always shows it.
  case unread(String)

  /// The dependency on one product of a package.
  ///
  /// - Parameter product: The product that the target links.
  /// - Returns: The `.product(name:package:)` dependency on `product`.
  public static func linking(_ product: ManifestProduct) -> TargetDependency {
    .product(name: product.name, package: product.package)
  }

  /// Reads one entry of a `dependencies` list.
  ///
  /// - Parameter entry: The text of the entry, with no space at its ends.
  init(reading entry: String) {
    if let byName = entry.wholeMatch(of: #/"(?<name>[^"]+)"/#) {
      self = .byName(String(byName.output.name))
      return
    }
    let product = #/\.product\(\s*name:\s*"(?<name>[^"]+)",\s*package:\s*"(?<package>[^"]+)"\s*\)/#
    if let match = entry.wholeMatch(of: product) {
      self = .product(name: String(match.output.name), package: String(match.output.package))
      return
    }
    self = .unread(entry)
  }

  /// The dependency as a failed check shows it.
  public var description: String {
    switch self {
    case .byName(let name): "\"\(name)\""
    case .product(let name, let package): "\(name) of \(package)"
    case .unread(let text): "unread entry \(text)"
    }
  }
}
