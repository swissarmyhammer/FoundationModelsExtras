/// The shape of a marketplace tree, as the host names it: the document that
/// marks a skill folder, the folder names that a scan skips, and the folder
/// that holds the partials of an entry.
///
/// This package does not know what a skill is. The host names its format,
/// thus the scan finds the skills of any dotfolder family. The scan reads
/// ``documentName`` and ``excludedDirectoryNames``. The snapshot writer reads
/// ``partialsDirectoryName``. The document of an agent folder is fixed:
/// ``MarketplaceLayer/agentDocumentName``.
public struct MarketplaceLayout: Sendable, Hashable {
  /// The folder names that a scan skips when the host names none: the git
  /// folder and the npm folder.
  public static let defaultExcludedDirectoryNames: Set<String> = [".git", "node_modules"]

  /// The partials folder name when the host names none: the `_partials`
  /// convention of the dotfolder stack.
  public static let defaultPartialsDirectoryName = "_partials"

  /// The name of the document that marks a skill folder, for example
  /// `SKILL.md`. A folder that holds a regular file with this name is one
  /// skill. The name has no default: the host names its format.
  public var documentName: String

  /// The folder names that a scan never reads into.
  public var excludedDirectoryNames: Set<String>

  /// The name of the folder that holds the partials of an entry.
  public var partialsDirectoryName: String

  /// Creates a layout.
  ///
  /// - Parameters:
  ///   - documentName: The name of the document that marks a skill folder.
  ///   - excludedDirectoryNames: The folder names that a scan skips. The
  ///     default is ``defaultExcludedDirectoryNames``.
  ///   - partialsDirectoryName: The name of the partials folder. The default
  ///     is ``defaultPartialsDirectoryName``.
  public init(
    documentName: String,
    excludedDirectoryNames: Set<String> = Self.defaultExcludedDirectoryNames,
    partialsDirectoryName: String = Self.defaultPartialsDirectoryName
  ) {
    self.documentName = documentName
    self.excludedDirectoryNames = excludedDirectoryNames
    self.partialsDirectoryName = partialsDirectoryName
  }
}
