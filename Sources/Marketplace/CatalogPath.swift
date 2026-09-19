/// The path rules of a ``CatalogFileSource`` tree: relative, separated by `/`,
/// and the empty path is the root.
internal enum CatalogPath {
  /// The separator of path components.
  static let separator: Character = "/"

  /// The component that names the current folder.
  private static let currentFolder = "."

  /// The component that names the parent folder.
  private static let parentFolder = ".."

  /// The prefix of an absolute path.
  private static let rootPrefix = "/"

  /// The prefix of a path in the home directory.
  private static let homePrefix = "~"

  /// The text that shows the root folder in a diagnostic.
  private static let rootDisplay = "."

  /// Normalizes a relative path from a catalog.
  ///
  /// - Parameter path: The path, for example `./skills/tdd`.
  /// - Returns: The path with no `.` component and no empty component, or
  ///   `nil` when the path is empty, absolute, starts with `~`, or has a
  ///   `..` component. The path `./` gives the empty path: the root.
  static func normalized(path: String) -> String? {
    guard isWellFormedRelativePath(path) else {
      return nil
    }
    return path.split(separator: separator).filter { $0 != currentFolder }.joined(separator: String(separator))
  }

  /// Resolves a relative path from a catalog against a folder of the tree.
  ///
  /// - Parameters:
  ///   - relativePath: The path, as the catalog writes it.
  ///   - folder: The normalized folder that the path is relative to.
  /// - Returns: The normalized path in the tree, or `nil` when
  ///   ``normalized(path:)`` refuses `relativePath`.
  static func resolved(relativePath: String, inFolder folder: String) -> String? {
    normalized(path: relativePath).map { $0.isEmpty ? folder : child(named: $0, of: folder) }
  }

  /// Adds one or more components to a folder path.
  ///
  /// - Parameters:
  ///   - name: The normalized components to add.
  ///   - folder: The normalized folder path. The empty path is the root.
  /// - Returns: The path of the child.
  static func child(named name: String, of folder: String) -> String {
    folder.isEmpty ? name : folder + String(separator) + name
  }

  /// Gives the last component of a path.
  ///
  /// - Parameter path: The normalized path.
  /// - Returns: The last component, or `nil` for the root.
  static func lastComponent(of path: String) -> String? {
    path.split(separator: separator).last.map(String.init)
  }

  /// Tells whether a name is one folder name.
  ///
  /// - Parameter name: The name.
  /// - Returns: `true` when the name is a normalized path with one
  ///   component.
  static func isSingleComponent(name: String) -> Bool {
    normalized(path: name) == name && !name.contains(separator)
  }

  /// Shows a path in the text of a diagnostic.
  ///
  /// - Parameter path: The normalized path.
  /// - Returns: The path, or `.` for the root.
  static func display(path: String) -> String {
    path.isEmpty ? rootDisplay : path
  }

  /// Tells whether a path is relative and stays inside its root.
  ///
  /// The rule is the one of the Skills `PathConfinement`: the path is not
  /// empty, it does not start with `/` or `~`, and no component is `..`.
  ///
  /// - Parameter path: The candidate path.
  /// - Returns: Whether `path` is well-formed.
  private static func isWellFormedRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix(rootPrefix), !path.hasPrefix(homePrefix) else {
      return false
    }
    return !path.split(separator: separator, omittingEmptySubsequences: true).contains(Substring(parentFolder))
  }
}
