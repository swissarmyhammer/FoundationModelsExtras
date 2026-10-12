/// The names in `Package.swift` that more than one test suite reads.
///
/// The suites that read the manifest as text live in different test targets.
/// Each of these targets links `FixtureSupport`, thus this type holds the one
/// copy of each name. A rename in the manifest then changes one place only.
public enum PackageManifest {
  /// The path of the manifest, relative to the package root.
  public static let path = "Package.swift"

  /// The name of the core target.
  public static let coreTargetName = "FoundationModelsExtras"

  /// The name of the marketplace target.
  public static let marketplaceTargetName = "Marketplace"

  /// The folder of the sources of the marketplace target, relative to the
  /// package root.
  public static let marketplaceSourcesPath = "Sources/\(marketplaceTargetName)"

  /// The libgit2 product, which the marketplace target links.
  public static let libgit2Product = ManifestProduct(name: "libgit2", package: "swift-libgit2")

  /// The tracing API product.
  public static let tracingProduct = ManifestProduct(name: "Tracing", package: "swift-distributed-tracing")
}

/// One product of a package dependency, as a target of the manifest names it.
public struct ManifestProduct: Hashable, Sendable {
  /// The name of the product.
  public let name: String

  /// The name of the package that gives the product.
  public let package: String

  /// Makes a product.
  ///
  /// - Parameters:
  ///   - name: The name of the product.
  ///   - package: The name of the package that gives the product.
  public init(name: String, package: String) {
    self.name = name
    self.package = package
  }

  /// The product as an entry of the `dependencies` list of a target writes
  /// it, for example `.product(name: "Tracing", package: "swift-distributed-tracing")`.
  public var dependencyText: String {
    #".product(name: "\#(name)", package: "\#(package)")"#
  }
}
