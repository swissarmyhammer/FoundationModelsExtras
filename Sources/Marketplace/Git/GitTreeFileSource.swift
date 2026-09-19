import Foundation
import libgit2

/// A ``CatalogFileSource`` over the tree of one commit in a bare repository
/// (marketplace.md §5.1 and §7.3 step 3).
///
/// The source reads the tree and blob objects directly. There is no checkout
/// and no work tree. A file read goes `git_commit_lookup` → `git_commit_tree`
/// → `git_tree_entry_bypath` → `git_blob_rawcontent`.
///
/// The mode of a tree entry gives its kind: `100644` is a file, `100755` an
/// executable file, `040000` a folder, `120000` a symbolic link whose target
/// is the text of its blob, and `160000` a submodule. libgit2 gives every
/// other mode as `100644`. The source never follows a symbolic link, and it
/// never reads into a submodule.
///
/// ``rootPath`` is the `path:` field of the marketplace source. It is a prefix
/// on every lookup, thus the resolver sees that subfolder as the root.
///
/// Each call opens the repository and frees each libgit2 object before it
/// returns. Thus the source holds no handle, and it is `Sendable`.
internal struct GitTreeFileSource: CatalogFileSource {
  /// The directory of the bare repository.
  let repositoryURL: URL

  /// The 40-hex SHA of the commit that the source reads.
  let commit: String

  /// The normalized folder of the tree that is the root of every lookup.
  /// The empty path is the root of the commit tree.
  let rootPath: String

  /// Makes a source over one commit.
  ///
  /// The initializer does no I/O. A commit that the repository does not
  /// hold fails at the first read.
  ///
  /// - Parameters:
  ///   - repositoryURL: The directory of the bare repository.
  ///   - commit: The 40-hex SHA of the commit.
  ///   - rootPath: The `path:` field of the source, or `nil` for the root
  ///     of the commit tree.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)`` when
  ///   `rootPath` is not a relative path in the tree.
  init(repositoryURL: URL, commit: String, rootPath: String? = nil) throws {
    self.repositoryURL = repositoryURL
    self.commit = commit
    self.rootPath = try rootPath.map { try Self.normalized(path: $0) } ?? ""
  }

  /// Reads the bytes of one file.
  ///
  /// - Parameter path: The path of the file, relative to ``rootPath``.
  /// - Returns: The bytes, or `nil` when no file is at the path. A folder, a
  ///   symbolic link, and a submodule are not files.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)``, or
  ///   ``GitTransportError/libgit2(code:message:)`` when libgit2 cannot read
  ///   the commit.
  func contents(atPath path: String) throws -> Data? {
    let treePath = try treePath(forPath: path)
    guard !treePath.isEmpty else {
      return nil
    }
    return try withRootTree { repository, root in
      try Self.withEntry(atPath: treePath, in: root) { entry in
        guard let entry, case .file = try Self.kind(of: entry, in: repository) else {
          return nil
        }
        return try Self.blobContents(of: entry, in: repository)
      }
    }
  }

  /// Lists the items of one folder.
  ///
  /// - Parameter path: The path of the folder, relative to ``rootPath``.
  ///   The empty path is ``rootPath``.
  /// - Returns: The items, sorted by name, or an empty list when no folder
  ///   is at the path.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)``, or
  ///   ``GitTransportError/libgit2(code:message:)`` when libgit2 cannot read
  ///   the commit.
  func entries(inDirectory path: String) throws -> [CatalogTreeEntry] {
    let treePath = try treePath(forPath: path)
    return try withRootTree { repository, root in
      guard !treePath.isEmpty else {
        return try Self.entries(of: root, in: repository)
      }
      return try Self.withEntry(atPath: treePath, in: root) { entry in
        guard let entry, git_tree_entry_filemode(entry) == GIT_FILEMODE_TREE else {
          return []
        }
        let folder = try LibGit2Transport.makeHandle(phase: .localRepository) { folder in
          git_tree_lookup(&folder, repository, git_tree_entry_id(entry))
        }
        defer { git_tree_free(folder) }
        return try Self.entries(of: folder, in: repository)
      }
    }
  }

  // MARK: - Paths

  /// Normalizes a path of the tree.
  ///
  /// - Parameter path: The path. The empty path is the root.
  /// - Returns: The path with no `.` component and no empty component.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)`` when the path
  ///   is absolute, starts with `~`, or has a `..` component.
  private static func normalized(path: String) throws -> String {
    guard !path.isEmpty else {
      return ""
    }
    guard let normalized = CatalogPath.normalized(path: path) else {
      throw CatalogFileSourceError.pathOutsideRoot(path)
    }
    return normalized
  }

  /// Adds ``rootPath`` to a path of the resolver.
  ///
  /// - Parameter path: The path, relative to ``rootPath``.
  /// - Returns: The path in the commit tree. The empty path is the root of
  ///   the commit tree.
  /// - Throws: ``CatalogFileSourceError/pathOutsideRoot(_:)``.
  private func treePath(forPath path: String) throws -> String {
    let relativePath = try Self.normalized(path: path)
    return relativePath.isEmpty ? rootPath : CatalogPath.child(named: relativePath, of: rootPath)
  }

  // MARK: - Objects

  /// Opens the repository, finds the tree of ``commit``, and gives both to
  /// `body`. Each object is freed when `body` returns.
  ///
  /// - Parameter body: The work on the repository and on the commit tree.
  /// - Returns: The result of `body`.
  /// - Throws: ``GitTransportError/libgit2(code:message:)`` when libgit2
  ///   cannot open the repository or read the commit, or the error of
  ///   `body`.
  private func withRootTree<Result>(
    body: (_ repository: OpaquePointer, _ root: OpaquePointer) throws -> Result
  ) throws -> Result {
    try LibGit2Transport.check(status: LibGit2Transport.libraryStartCount, phase: .localRepository)
    let repository = try LibGit2Transport.makeHandle(phase: .localRepository) { repository in
      git_repository_open_bare(&repository, repositoryURL.path)
    }
    defer { git_repository_free(repository) }
    var commitID = git_oid()
    try LibGit2Transport.check(status: git_oid_fromstr(&commitID, commit), phase: .localRepository)
    let commitObject = try LibGit2Transport.makeHandle(phase: .localRepository) { commitObject in
      git_commit_lookup(&commitObject, repository, &commitID)
    }
    defer { git_commit_free(commitObject) }
    let root = try LibGit2Transport.makeHandle(phase: .localRepository) { root in
      git_commit_tree(&root, commitObject)
    }
    defer { git_tree_free(root) }
    return try body(repository, root)
  }

  /// Finds the entry at a path of a tree, and gives it to `body`. The entry
  /// is freed when `body` returns.
  ///
  /// libgit2 walks each component as a folder, thus a path that goes
  /// through a symbolic link or a submodule has no entry.
  ///
  /// - Parameters:
  ///   - path: The path in the tree. It is not empty.
  ///   - tree: The tree.
  ///   - body: The work on the entry, which is `nil` when no entry is at
  ///     the path.
  /// - Returns: The result of `body`.
  /// - Throws: ``GitTransportError/libgit2(code:message:)`` for a libgit2
  ///   failure that is not a missing path, or the error of `body`.
  private static func withEntry<Result>(
    atPath path: String, in tree: OpaquePointer, body: (_ entry: OpaquePointer?) throws -> Result
  ) throws -> Result {
    var entry: OpaquePointer?
    let status = git_tree_entry_bypath(&entry, tree, path)
    defer { git_tree_entry_free(entry) }
    guard status != GIT_ENOTFOUND.rawValue else {
      return try body(nil)
    }
    try LibGit2Transport.check(status: status, phase: .localRepository)
    return try body(entry)
  }

  /// Lists the entries of one tree.
  ///
  /// - Parameters:
  ///   - tree: The tree.
  ///   - repository: The repository that holds the blobs of symbolic links.
  /// - Returns: One item for each entry, sorted by name, as
  ///   ``LocalCatalogFileSource`` sorts. Git sorts a folder as if its name
  ///   ends in `/`, which is a different order.
  /// - Throws: ``GitTransportError/libgit2(code:message:)`` when the blob of
  ///   a symbolic link cannot be read.
  private static func entries(of tree: OpaquePointer, in repository: OpaquePointer) throws -> [CatalogTreeEntry] {
    try (0..<git_tree_entrycount(tree))
      .compactMap { git_tree_entry_byindex(tree, $0) }
      .map { entry in
        CatalogTreeEntry(name: String(cString: git_tree_entry_name(entry)), kind: try kind(of: entry, in: repository))
      }
      .sorted { $0.name < $1.name }
  }

  /// Gives the kind of one tree entry from its mode.
  ///
  /// - Parameters:
  ///   - entry: The tree entry.
  ///   - repository: The repository that holds the blob of a symbolic link.
  /// - Returns: The kind. libgit2 normalizes the mode, thus each mode that
  ///   is not a folder, a submodule, a symbolic link, or an executable file
  ///   is a regular file.
  /// - Throws: ``GitTransportError/libgit2(code:message:)`` when the blob of
  ///   a symbolic link cannot be read.
  private static func kind(of entry: OpaquePointer, in repository: OpaquePointer) throws -> CatalogTreeEntry.Kind {
    switch git_tree_entry_filemode(entry) {
    case GIT_FILEMODE_TREE:
      .directory
    case GIT_FILEMODE_COMMIT:
      .submodule
    case GIT_FILEMODE_LINK:
      .symlink(target: String(decoding: try blobContents(of: entry, in: repository), as: UTF8.self))
    case GIT_FILEMODE_BLOB_EXECUTABLE:
      .file(isExecutable: true)
    default:
      .file(isExecutable: false)
    }
  }

  /// Reads the bytes of the blob that a tree entry names.
  ///
  /// - Parameters:
  ///   - entry: The tree entry of a file or of a symbolic link.
  ///   - repository: The repository that holds the blob.
  /// - Returns: The bytes of the blob.
  /// - Throws: ``GitTransportError/libgit2(code:message:)`` when the blob
  ///   cannot be read.
  private static func blobContents(of entry: OpaquePointer, in repository: OpaquePointer) throws -> Data {
    let blob = try LibGit2Transport.makeHandle(phase: .localRepository) { blob in
      git_blob_lookup(&blob, repository, git_tree_entry_id(entry))
    }
    defer { git_blob_free(blob) }
    let size = Int(git_blob_rawsize(blob))
    guard size > 0, let bytes = git_blob_rawcontent(blob) else {
      return Data()
    }
    return Data(bytes: bytes, count: size)
  }
}
