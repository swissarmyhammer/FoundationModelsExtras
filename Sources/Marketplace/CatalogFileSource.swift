import Foundation

/// Reads the files of one marketplace tree for the catalog resolver
/// (marketplace.md §5.2).
///
/// The resolver does not know git. A folder on the disk gives this protocol
/// through the local file source, which card ^7z1w5f8 moves with the
/// resolver. The tree of a fetched commit gives it through
/// ``GitTreeFileSource``.
///
/// Every path is relative to the root of the tree. The components are
/// separated by `/`, and the empty path is the root. The resolver never sends
/// a path that starts with `/` or `~`, or that has a `..` component.
internal protocol CatalogFileSource: Sendable {
  /// Reads the bytes of one file.
  ///
  /// - Parameter path: The path of the file, relative to the root.
  /// - Returns: The bytes, or `nil` when no file is at the path.
  /// - Throws: An error when the path is not in the tree, or when the file
  ///   cannot be read.
  func contents(atPath path: String) throws -> Data?

  /// Lists the items of one folder.
  ///
  /// - Parameter path: The path of the folder, relative to the root. The
  ///   empty path is the root.
  /// - Returns: The items, sorted by name, or an empty list when no folder
  ///   is at the path.
  /// - Throws: An error when the path is not in the tree, or when the
  ///   folder cannot be read.
  func entries(inDirectory path: String) throws -> [CatalogTreeEntry]
}

/// One item of a folder in a marketplace tree.
internal struct CatalogTreeEntry: Sendable, Hashable {
  /// What an item is.
  enum Kind: Sendable, Hashable {
    /// A regular file. `isExecutable` tells whether the file has the
    /// execute permission.
    case file(isExecutable: Bool)

    /// A folder.
    case directory

    /// A symbolic link, with the path that it points to. The resolver
    /// never follows a symbolic link that it finds in a folder list.
    case symlink(target: String)

    /// A git submodule. A folder on the disk never gives this kind.
    case submodule
  }

  /// The name of the item, with no folder path.
  var name: String

  /// What the item is.
  var kind: Kind
}

/// Why a ``CatalogFileSource`` refused a path.
internal enum CatalogFileSourceError: Error, Equatable, Sendable {
  /// The path is not a relative path, or it resolves, directly or through a
  /// symbolic link, to a location outside the root.
  case pathOutsideRoot(String)
}
