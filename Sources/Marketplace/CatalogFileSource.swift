import Foundation
import FoundationModelsExtras

/// Reads the files of one marketplace tree for ``CatalogResolver``
/// (marketplace.md §5.2).
///
/// The resolver does not know git. A folder on the disk gives this protocol
/// through ``LocalCatalogFileSource``. The tree of a fetched commit gives it
/// through ``GitTreeFileSource``.
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

/// A ``CatalogFileSource`` over a folder on the disk, for a `file://` source
/// and for tests.
///
/// A path that resolves outside ``root`` throws
/// ``CatalogFileSourceError/pathOutsideRoot(_:)``. ``CatalogPath`` refuses a
/// path that names an escape, and the core `PathConfinement` refuses a path
/// that escapes through a symbolic link, thus the rule is the same rule as
/// for the dotfolder stack. A symbolic link in the root that points into the
/// root is followed when a path goes through it.
internal struct LocalCatalogFileSource: CatalogFileSource {
  /// What is at a resolved location on the disk.
  private enum ItemState {
    /// Nothing is at the location.
    case missing

    /// A file is at the location.
    case file

    /// A folder is at the location.
    case folder
  }

  /// The resource keys that ``entries(inDirectory:)`` reads for each item.
  private static let entryKeys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isExecutableKey]

  /// The root folder of the tree.
  let root: URL

  /// Reads the bytes of one file.
  ///
  /// - Parameter path: The path of the file, relative to ``root``.
  /// - Returns: The bytes, or `nil` when no file is at the path.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)``, or the error
  ///   of the read.
  func contents(atPath path: String) throws -> Data? {
    let url = try resolvedURL(forPath: path)
    guard Self.state(ofItemAt: url) == .file else {
      return nil
    }
    return try Data(contentsOf: url)
  }

  /// Lists the items of one folder.
  ///
  /// - Parameter path: The path of the folder, relative to ``root``. The
  ///   empty path is ``root``.
  /// - Returns: The items, sorted by name, or an empty list when no folder
  ///   is at the path.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)``, or the error
  ///   of the folder list.
  func entries(inDirectory path: String) throws -> [CatalogTreeEntry] {
    let url = try resolvedURL(forPath: path)
    guard Self.state(ofItemAt: url) == .folder else {
      return []
    }
    return try FileManager.default
      .contentsOfDirectory(at: url, includingPropertiesForKeys: Array(Self.entryKeys), options: [])
      .map(Self.entry(at:))
      .sorted { $0.name < $1.name }
  }

  /// Resolves a tree path to a location in ``root``.
  ///
  /// - Parameter path: The path, relative to ``root``.
  /// - Returns: ``root`` for the empty path, else the confined location.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)`` when the path
  ///   is not a relative path in ``root``.
  private func resolvedURL(forPath path: String) throws -> URL {
    guard !path.isEmpty else {
      return root
    }
    guard let relativePath = CatalogPath.normalized(path: path) else {
      throw CatalogFileSourceError.pathOutsideRoot(path)
    }
    let url = root.appendingPathComponent(relativePath)
    guard PathConfinement.isConfined(url, to: root) else {
      throw CatalogFileSourceError.pathOutsideRoot(path)
    }
    return url
  }

  /// Tells what is at a location.
  ///
  /// - Parameter url: The location.
  /// - Returns: The state of the item at the location.
  private static func state(ofItemAt url: URL) -> ItemState {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return .missing
    }
    return isDirectory.boolValue ? .folder : .file
  }

  /// Makes the entry of one item of a folder list.
  ///
  /// - Parameter url: The location of the item. The location is not
  ///   resolved, so a symbolic link stays a symbolic link.
  /// - Returns: The entry.
  /// - Throws: The error of the resource read or of the link read.
  private static func entry(at url: URL) throws -> CatalogTreeEntry {
    let values = try url.resourceValues(forKeys: entryKeys)
    guard values.isSymbolicLink != true else {
      return try CatalogTreeEntry(
        name: url.lastPathComponent,
        kind: .symlink(target: FileManager.default.destinationOfSymbolicLink(atPath: url.path)))
    }
    let kind: CatalogTreeEntry.Kind =
      values.isDirectory == true ? .directory : .file(isExecutable: values.isExecutable == true)
    return CatalogTreeEntry(name: url.lastPathComponent, kind: kind)
  }
}
