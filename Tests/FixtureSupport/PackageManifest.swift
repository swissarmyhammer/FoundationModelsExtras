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
  /// The read removes each line comment and each block comment of the
  /// manifest first, thus a comment is never an entry. Then it finds the
  /// declaration of each kind of target with the name `target`, and reads its
  /// `dependencies` argument in any position among the other arguments.
  ///
  /// - Parameters:
  ///   - target: The name of the target.
  ///   - manifest: The text of the manifest.
  /// - Returns: The entries, in the order of the manifest. A target with no
  ///   `dependencies` argument gives no entry. A `dependencies` value that is
  ///   not a list literal gives one ``TargetDependency/unread(_:)`` entry.
  /// - Throws: A ``FixtureError`` when the manifest declares no such target.
  public static func dependencies(ofTarget target: String, in manifest: String) throws -> [TargetDependency] {
    let arguments = try declarationArguments(ofTarget: target, in: removingComments(from: manifest))
    guard let value = value(ofArgument: "dependencies", in: arguments) else {
      return []
    }
    guard let entries = listEntries(of: value) else {
      return [.unread(String(value))]
    }
    return entries.map(TargetDependency.init(reading:))
  }

  /// The name of each factory of PackageDescription that declares a target.
  private static let targetKinds = [
    "target", "executableTarget", "testTarget", "macro", "plugin", "binaryTarget", "systemLibrary",
  ]

  /// Reads the arguments of the declaration of one target.
  ///
  /// - Parameters:
  ///   - target: The name of the target.
  ///   - code: The text of the manifest, with no comment.
  /// - Returns: The text of each argument of the declaration.
  /// - Throws: A ``FixtureError`` when the manifest declares no such target.
  private static func declarationArguments(ofTarget target: String, in code: String) throws -> [String] {
    let kinds = targetKinds.joined(separator: "|")
    let name = NSRegularExpression.escapedPattern(for: target)
    let declaration = try Regex(#"\.(?:\#(kinds))\((?=\s*name:\s*"\#(name)")"#)
    guard let start = code.firstMatch(of: declaration) else {
      throw FixtureError(message: "the manifest declares no target named \(target)")
    }
    return topLevelEntries(of: code[start.range.upperBound...])
  }

  /// Reads the name of each target of the manifest of the package.
  ///
  /// - Returns: The names, in the order of the manifest.
  /// - Throws: A ``FixtureError`` when the manifest cannot be read, or when
  ///   its `targets` list cannot be read.
  public static func targetNames() throws -> [String] {
    try targetNames(in: text())
  }

  /// Reads the name of each target of a manifest.
  ///
  /// The read takes each entry of the `targets` argument of the `Package`
  /// call, of each kind of target. It does not use the declaration forms
  /// that ``dependencies(ofTarget:in:)`` knows, thus a check can give each
  /// name to that read, and a target of a form that the read does not know
  /// then fails the check.
  ///
  /// - Parameter manifest: The text of the manifest.
  /// - Returns: The names, in the order of the manifest.
  /// - Throws: A ``FixtureError`` when the manifest makes no `Package` with a
  ///   `targets` list, or when an entry of the list has no name.
  public static func targetNames(in manifest: String) throws -> [String] {
    let code = removingComments(from: manifest)
    guard let call = code.firstMatch(of: #/\bPackage\(/#) else {
      throw FixtureError(message: "the manifest makes no Package")
    }
    let arguments = topLevelEntries(of: code[call.range.upperBound...])
    guard let value = value(ofArgument: "targets", in: arguments), let entries = listEntries(of: value) else {
      throw FixtureError(message: "the manifest gives the Package no targets list")
    }
    return try entries.map(targetName(of:))
  }

  /// Reads the name of one entry of the `targets` list.
  ///
  /// - Parameter entry: The text of the entry, for example
  ///   `.target(name: "Core", dependencies: [])`.
  /// - Returns: The name of the target.
  /// - Throws: A ``FixtureError`` when the entry does not start with a call
  ///   with a `name:` argument.
  private static func targetName(of entry: String) throws -> String {
    guard let match = entry.prefixMatch(of: #/\.\w+\(\s*name:\s*"(?<name>[^"]+)"/#) else {
      throw FixtureError(message: "the targets list has an entry with no name: \(entry)")
    }
    return String(match.output.name)
  }

  /// One token of the manifest: a string literal, a line comment, a block
  /// comment, or one character.
  ///
  /// A string literal is one token, thus a comment marker, a comma or a
  /// bracket inside it is never read as code.
  private static var token: Regex<Substring> {
    #/"(?:[^"\\\n]|\\.)*"|//[^\n]*|/\*(?s:.*?)\*/|(?s:.)/#
  }

  /// Removes each line comment and each block comment of a manifest. A
  /// comment marker inside a string literal stays.
  ///
  /// - Parameter manifest: The text of the manifest.
  /// - Returns: The text with one space in place of each comment.
  private static func removingComments(from manifest: String) -> String {
    manifest.replacing(token) { match in
      match.output.hasPrefix("//") || match.output.hasPrefix("/*") ? " " : match.output
    }
  }

  /// Gives the value of one labeled argument of a call.
  ///
  /// - Parameters:
  ///   - label: The label of the argument, with no colon.
  ///   - arguments: The text of each argument of the call.
  /// - Returns: The text after the label and the colon, or `nil` when no
  ///   argument has the label.
  private static func value(ofArgument label: String, in arguments: [String]) -> Substring? {
    let prefix = "\(label):"
    return arguments.first { $0.hasPrefix(prefix) }.map { $0.dropFirst(prefix.count).drop(while: \.isWhitespace) }
  }

  /// Gives the entries of a list literal.
  ///
  /// - Parameter value: The text of a value.
  /// - Returns: The text of each entry, or `nil` when the value is not a list
  ///   literal.
  private static func listEntries(of value: Substring) -> [String]? {
    guard value.first == "[" else { return nil }
    return topLevelEntries(of: value.dropFirst())
  }

  /// Splits the text of a list or of the arguments of a call at each comma
  /// that no parenthesis, no bracket and no string literal of an entry holds.
  /// The split stops at the bracket or the parenthesis that closes the list.
  ///
  /// - Parameter list: The text after the opening bracket of the list, or
  ///   after the opening parenthesis of the call. It holds no comment.
  /// - Returns: The text of each entry that is not empty, with no space at
  ///   its ends.
  private static func topLevelEntries(of list: Substring) -> [String] {
    var entries = [""]
    var depth = 0
    for match in list.matches(of: token) {
      switch match.output {
      case ")" where depth == 0, "]" where depth == 0:
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
      entries[entries.count - 1].append(contentsOf: match.output)
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
