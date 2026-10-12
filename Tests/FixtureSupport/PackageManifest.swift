import Foundation

/// The names in `Package.swift` that more than one test suite reads, and the
/// one read of the manifest text and of the `dependencies` list of a target.
///
/// The suites that read the manifest as text live in different test targets.
/// Each of these targets links `FixtureSupport`, thus this type holds the one
/// copy of each name and of each read. A rename in the manifest then changes
/// one place only.
public enum PackageManifest {
  /// The path of the manifest, relative to the package root.
  public static let path = "Package.swift"

  /// The folder of the library sources, relative to the package root.
  public static let sourcesPath = "Sources"

  /// The name of the core target.
  public static let coreTargetName = "FoundationModelsExtras"

  /// The name of the marketplace target.
  public static let marketplaceTargetName = "Marketplace"

  /// The folder of the sources of the marketplace target, relative to the
  /// package root.
  public static let marketplaceSourcesPath = "\(sourcesPath)/\(marketplaceTargetName)"

  /// The libgit2 product, which the marketplace target links.
  public static let libgit2Product = ManifestProduct(name: "libgit2", package: "swift-libgit2")

  /// The tracing API product.
  public static let tracingProduct = ManifestProduct(name: "Tracing", package: "swift-distributed-tracing")

  /// Reads the text of the manifest.
  ///
  /// - Returns: The text of `Package.swift`.
  /// - Throws: A ``FixtureError`` when the manifest cannot be read.
  public static func text() throws -> String {
    try FixtureFile.text(path).get()
  }

  /// Reads each entry of the `dependencies` list of one target of the
  /// manifest of the package.
  ///
  /// - Parameter target: The name of the target.
  /// - Returns: The entries, in the order of the manifest.
  /// - Throws: A ``FixtureError`` when the manifest cannot be read, or when
  ///   it declares no such target.
  public static func dependencies(ofTarget target: String) throws -> [TargetDependency] {
    try dependencies(ofTarget: target, in: text())
  }

  /// Reads each entry of the `dependencies` list of one target.
  ///
  /// The read removes each comment of the manifest first, thus a comment is
  /// never an entry. Then it takes the text after the opening bracket of the
  /// list of the `.target` declaration with the name `target`.
  ///
  /// - Parameters:
  ///   - target: The name of the target.
  ///   - manifest: The text of the manifest.
  /// - Returns: The entries, in the order of the manifest.
  /// - Throws: A ``FixtureError`` when the manifest declares no such target.
  public static func dependencies(ofTarget target: String, in manifest: String) throws -> [TargetDependency] {
    let stringOrComment = #/"[^"\n]*"|//[^\n]*/#
    let code = manifest.replacing(stringOrComment) { $0.output.hasPrefix("//") ? "" : $0.output }
    let declaration = try Regex(#"\.target\(\s*name:\s*"\#(target)",\s*dependencies:\s*\["#)
    guard let start = code.firstMatch(of: declaration) else {
      throw FixtureError(message: "the manifest declares no target named \(target) with a dependencies list")
    }
    return topLevelEntries(of: code[start.range.upperBound...]).map(TargetDependency.init(reading:))
  }

  /// Splits the text of a list at each comma that no parenthesis and no
  /// bracket of an entry holds. The split stops at the bracket that closes the
  /// list.
  ///
  /// - Parameter list: The text after the opening bracket of the list.
  /// - Returns: The text of each entry that is not empty, with no space at
  ///   its ends.
  private static func topLevelEntries(of list: Substring) -> [String] {
    var entries = [""]
    var depth = 0
    for character in list {
      switch character {
      case "]" where depth == 0:
        return trimmed(entries)
      case "," where depth == 0:
        entries.append("")
        continue
      case "(", "[":
        depth += 1
      case ")", "]":
        depth -= 1
      default:
        break
      }
      entries[entries.count - 1].append(character)
    }
    return trimmed(entries)
  }

  /// Removes the space at the ends of each entry, and each entry that is then
  /// empty.
  ///
  /// - Parameter entries: The text of the entries.
  /// - Returns: The entries that are not empty.
  private static func trimmed(_ entries: [String]) -> [String] {
    entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }
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
