import Foundation

/// Why the writer refused a tree (marketplace.md §7.3 step 4).
///
/// The writer deletes the staged folder before it throws, so a refused tree
/// leaves nothing on the disk.
internal enum SnapshotError: Error, Equatable, Sendable {
  /// One item of a folder has a name that can leave the folder that holds
  /// it, or that names the folder itself.
  case unsafeEntryName(directory: String, name: String)

  /// A symbolic link points outside the skill folder that holds it.
  case escapingSymlink(path: String, target: String)

  /// A folder holds a git submodule. The writer reads one tree, so it has
  /// no second repository to read.
  case submodule(path: String)

  /// The tree holds more files than the policy permits. The path names the
  /// file that reached the limit.
  case tooManyFiles(path: String, limit: Int)

  /// The tree holds more bytes than the policy permits. The path names the
  /// file that reached the limit.
  case tooManyBytes(path: String, limit: Int)
}

extension SnapshotError: CustomStringConvertible {
  /// One sentence that names the path in the tree and what is wrong.
  var description: String {
    switch self {
    case .unsafeEntryName(let directory, let name):
      #"The folder "\#(CatalogPath.display(path: directory))" holds the name "\#(name)", which cannot go into a snapshot path."#
    case .escapingSymlink(let path, let target):
      #"The link "\#(path)" points to "\#(target)", which is outside its skill folder."#
    case .submodule(let path):
      #"The entry "\#(path)" is a git submodule, which a snapshot cannot hold."#
    case .tooManyFiles(let path, let limit):
      #"The snapshot reached the limit of \#(limit) files at "\#(path)"."#
    case .tooManyBytes(let path, let limit):
      #"The snapshot reached the limit of \#(limit) bytes at "\#(path)"."#
    }
  }
}

/// What one snapshot write copied, and what it found (marketplace.md §7.3).
internal struct SnapshotReport: Sendable, Hashable {
  /// The number of files that the write copied. A symbolic link counts as
  /// one file.
  var fileCount: Int

  /// The number of bytes that the write copied.
  var byteCount: Int

  /// The findings of the write. A finding does not stop the write.
  var diagnostics: [MarketplaceDiagnostic]
}

/// Writes the selected skills of one resolved catalog into one flat folder
/// (marketplace.md §7.3 steps 3 and 4, and §4.2).
///
/// The result is a layer root: `<skill>/…` for each selected skill,
/// `agents/<name>` for each selected agent file, plus the partials folder
/// that the ``MarketplaceLayout`` of the host names.
///
/// The snapshot is flat: the folders between a plugin source and a skill,
/// for example `skills/` and `skills/group/`, do not exist in it. Thus the
/// partials of those folders merge into `<snapshot>/<partials folder>/`.
/// For each selected skill, the writer takes each folder from its source
/// root (``ResolvedCatalog/sourceRoots``), or from the root of a tree with
/// no catalog, down to the folder that holds the skill. It copies the
/// partials folder of each of these folders one time, from the least
/// specific (the fewest path components) to the most specific. For a skill
/// at `skills/group/review/`, the order is `_partials/`,
/// `skills/_partials/`, then `skills/group/_partials/`. A more specific copy
/// replaces a less specific copy with no diagnostic, whatever the catalog
/// order. Two folders at the same level of specificity that give a partial
/// of the same name give one diagnostic, and the later one in catalog order
/// wins. A partials folder inside a skill folder goes with the skill folder.
///
/// A known limit of the flat snapshot: each skill and each agent file sees
/// the merged partials of all these folders, because they merge into the one
/// partials folder of the snapshot.
///
/// The input is any ``CatalogFileSource``, so the same code writes a folder
/// on the disk and the tree of a fetched commit. There is no checkout and no
/// work tree.
///
/// ``MarketplaceCache/install(snapshotAt:sha:ref:)`` then takes the folder
/// that this writer staged.
internal enum SnapshotWriter {
  /// The first line of a large file storage pointer. A file that starts
  /// with it holds the address of the content, not the content.
  static let largeFileStoragePrefix = "version https://git-lfs.github.com/spec/v1"

  /// Writes one snapshot of the selected skills.
  ///
  /// The call makes `temporaryDirectory`, writes the tree into it, and
  /// gives a report. On any refusal it deletes `temporaryDirectory` and
  /// throws, so a refused tree leaves nothing on the disk.
  ///
  /// - Parameters:
  ///   - catalog: The skills that ``CatalogResolver`` selected.
  ///   - source: The files of the marketplace tree.
  ///   - temporaryDirectory: The staged folder to write. It must not exist
  ///     yet, and it must be on the same volume as the cache, because the
  ///     install moves it.
  ///   - layout: The shape of the tree. The writer reads the name of the
  ///     partials folder from it.
  ///   - limits: The policy limits of the write.
  /// - Returns: The counts and the findings of the write.
  /// - Throws: ``SnapshotError`` when the tree breaks a rule of §7.3 step
  ///   4, else the error of a read or of a write.
  static func write(
    catalog: ResolvedCatalog, from source: any CatalogFileSource, to temporaryDirectory: URL,
    layout: MarketplaceLayout, limits: SnapshotLimits
  ) throws -> SnapshotReport {
    var run = SnapshotRun(
      source: source, destination: temporaryDirectory, limits: limits, marketplaceID: catalog.name,
      partialsDirectoryName: layout.partialsDirectoryName)
    do {
      try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
      try run.copySkills(catalog.skills)
      try run.copyAgents(catalog.agents)
      try run.copyPartials(ofSourceRoots: catalog.sourceRoots, skills: catalog.skills)
    } catch {
      try? FileManager.default.removeItem(at: temporaryDirectory)
      throw error
    }
    return run.report
  }
}

/// The state of one snapshot write: where it reads, where it writes, what it
/// counted, and what it already wrote.
///
/// ``SnapshotWriter`` reads it, thus it is `fileprivate` and not `private`.
fileprivate struct SnapshotRun {
  /// The permissions of a file that keeps its execute bit.
  private static let executableFileMode: NSNumber = 0o755

  /// The name of the parent folder, which walks out of a folder.
  private static let parentDirectoryName = ".."

  /// The name of the current folder, which names no child.
  private static let currentDirectoryName = "."

  /// The characters that make one name more than one name.
  private static let nameSeparators: Set<Character> = ["/", "\\"]

  /// The prefix of a path that is not relative to the folder that holds the
  /// link.
  private static let absolutePathPrefixes = ["/", "~"]

  /// The number of levels of the folder that a symbolic link may point to
  /// at the shallowest: the root of its own skill folder.
  private static let shallowestLinkLevel = 0

  /// The path of the root of the tree, where the walk of a skill with no
  /// source root above it starts.
  private static let treeRoot = ""

  /// The files of the marketplace tree.
  let source: any CatalogFileSource

  /// The staged folder that the write makes.
  let destination: URL

  /// The policy limits of the write.
  let limits: SnapshotLimits

  /// The marketplace that each diagnostic names.
  let marketplaceID: String?

  /// The name of the folder that holds the partials of an entry, from the
  /// ``MarketplaceLayout`` of the host.
  let partialsDirectoryName: String

  /// The counts and the findings so far.
  var report = SnapshotReport(fileCount: 0, byteCount: 0, diagnostics: [])

  /// The tree path that wrote each snapshot path, so that a second write of
  /// one snapshot path gives a diagnostic that names both sides.
  private var writtenPaths: [String: String] = [:]

  // MARK: - The steps of one write

  /// Copies the folder of each selected skill to `<snapshot>/<name>/`.
  ///
  /// - Parameter skills: The selected skills, in catalog order.
  /// - Throws: ``SnapshotError``, else the error of a read or of a write.
  mutating func copySkills(_ skills: [ResolvedSkill]) throws {
    for skill in skills {
      let name = try Self.validated(name: skill.name, inDirectory: skill.path)
      try copyTree(fromTreePath: skill.path, toRelativePath: name, depth: 0)
    }
  }

  /// Copies each selected agent file to `<snapshot>/agents/<name>`.
  ///
  /// The copy reads no text of an agent file. An agent file is a document,
  /// thus the copy does not keep an execute bit. Each file counts toward
  /// the policy limits, as a file of a skill folder does.
  ///
  /// - Parameter agents: The selected agent files, one for each name.
  /// - Throws: ``SnapshotError``, else the error of a read or of a write.
  mutating func copyAgents(_ agents: [ResolvedAgent]) throws {
    guard !agents.isEmpty else {
      return
    }
    let folder = MarketplaceLayer.agentsDirectoryName
    try FileManager.default.createDirectory(at: url(forRelativePath: folder), withIntermediateDirectories: true)
    for agent in agents {
      let name = try Self.validated(name: agent.name, inDirectory: CatalogPath.parent(of: agent.path))
      try copyFile(
        fromTreePath: agent.path, toRelativePath: CatalogPath.child(named: name, of: folder), isExecutable: false)
    }
  }

  /// Copies the partials folder of each source root, and of each folder
  /// from a source root down to a selected skill, to
  /// `<snapshot>/<partials folder>/`.
  ///
  /// The copy goes one level of specificity at a time, from the fewest path
  /// components to the most. Each folder is copied one time. Two folders at
  /// the same level can hold a partial of the same name. The later folder in
  /// catalog order wins, and the write records one diagnostic. After each
  /// level, the run forgets these writes, so that a more specific folder
  /// replaces them with no diagnostic.
  ///
  /// - Parameters:
  ///   - roots: The source roots, in catalog order.
  ///   - skills: The selected skills, in catalog order.
  /// - Throws: ``SnapshotError``, else the error of a read or of a write.
  mutating func copyPartials(ofSourceRoots roots: [String], skills: [ResolvedSkill]) throws {
    for level in Self.specificityLevels(of: Self.partialsFolders(ofSourceRoots: roots, skills: skills)) {
      for folder in level {
        try copyPartialsFolder(of: folder)
      }
      forgetPartialsWrites()
    }
  }

  /// Copies the partials folder of one folder of the tree to
  /// `<snapshot>/<partials folder>/`.
  ///
  /// - Parameter folder: The folder in the tree that holds the partials
  ///   folder. The empty path is the root.
  /// - Throws: ``SnapshotError``, else the error of a read or of a write.
  private mutating func copyPartialsFolder(of folder: String) throws {
    try copyTree(
      fromTreePath: CatalogPath.child(named: partialsDirectoryName, of: folder),
      toRelativePath: partialsDirectoryName,
      depth: 0)
  }

  // MARK: - The copy

  /// Copies one folder of the tree, and every folder under it.
  ///
  /// A folder with no item writes nothing, so a marketplace with no
  /// partials folder gets no empty folder in its snapshot.
  ///
  /// - Parameters:
  ///   - treePath: The folder in the marketplace tree.
  ///   - relativePath: The folder in the snapshot, relative to
  ///     ``destination``.
  ///   - depth: How many levels the folder is under the root of the skill
  ///     folder that holds it. A symbolic link may not walk above that
  ///     root.
  /// - Throws: ``SnapshotError``, else the error of a read or of a write.
  private mutating func copyTree(fromTreePath treePath: String, toRelativePath relativePath: String, depth: Int)
    throws
  {
    let entries = try source.entries(inDirectory: treePath)
    guard !entries.isEmpty else {
      return
    }
    try FileManager.default.createDirectory(at: url(forRelativePath: relativePath), withIntermediateDirectories: true)
    for entry in entries {
      let name = try Self.validated(name: entry.name, inDirectory: treePath)
      let childTreePath = CatalogPath.child(named: name, of: treePath)
      let childRelativePath = CatalogPath.child(named: name, of: relativePath)
      try copy(
        entry: entry, fromTreePath: childTreePath, toRelativePath: childRelativePath, depth: depth)
    }
  }

  /// Copies one item of a folder.
  ///
  /// - Parameters:
  ///   - entry: The item to copy.
  ///   - treePath: The item in the marketplace tree.
  ///   - relativePath: The item in the snapshot, relative to
  ///     ``destination``.
  ///   - depth: How many levels the folder that holds the item is under the
  ///     root of its skill folder.
  /// - Throws: ``SnapshotError``, else the error of a read or of a write.
  private mutating func copy(
    entry: CatalogTreeEntry, fromTreePath treePath: String, toRelativePath relativePath: String, depth: Int
  ) throws {
    switch entry.kind {
    case .directory:
      try copyTree(fromTreePath: treePath, toRelativePath: relativePath, depth: depth + 1)
    case .file(let isExecutable):
      try copyFile(fromTreePath: treePath, toRelativePath: relativePath, isExecutable: isExecutable)
    case .symlink(let target):
      try copySymlink(
        target: target, fromTreePath: treePath, toRelativePath: relativePath, depth: depth)
    case .submodule:
      throw SnapshotError.submodule(path: treePath)
    }
  }

  /// Copies one file, and keeps its execute bit.
  ///
  /// - Parameters:
  ///   - treePath: The file in the marketplace tree.
  ///   - relativePath: The file in the snapshot, relative to
  ///     ``destination``.
  ///   - isExecutable: Whether the file has the execute permission.
  /// - Throws: ``SnapshotError`` when the file reaches a limit, else the
  ///   error of the read or of the write.
  private mutating func copyFile(fromTreePath treePath: String, toRelativePath relativePath: String, isExecutable: Bool)
    throws
  {
    guard let data = try source.contents(atPath: treePath) else {
      return
    }
    try count(file: treePath, bytes: data.count)
    note(write: treePath, toRelativePath: relativePath)
    notePointer(file: treePath, data: data)
    let file = url(forRelativePath: relativePath)
    try Self.removeEarlierItem(at: file)
    try data.write(to: file)
    guard isExecutable else {
      return
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: Self.executableFileMode], ofItemAtPath: file.path)
  }

  /// Copies one symbolic link that stays in its own skill folder.
  ///
  /// - Parameters:
  ///   - target: The path that the link points to.
  ///   - treePath: The link in the marketplace tree.
  ///   - relativePath: The link in the snapshot, relative to
  ///     ``destination``.
  ///   - depth: How many levels the folder that holds the link is under the
  ///     root of its skill folder.
  /// - Throws: ``SnapshotError/escapingSymlink(path:target:)`` when the
  ///   target leaves the skill folder, else the error of the write.
  private mutating func copySymlink(
    target: String, fromTreePath treePath: String, toRelativePath relativePath: String, depth: Int
  ) throws {
    guard Self.stays(inFolderAtDepth: depth, target: target) else {
      throw SnapshotError.escapingSymlink(path: treePath, target: target)
    }
    try count(file: treePath, bytes: 0)
    note(write: treePath, toRelativePath: relativePath)
    let link = url(forRelativePath: relativePath)
    try Self.removeEarlierItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
  }

  // MARK: - Limits

  /// Counts one file of the snapshot, and checks the policy limits.
  ///
  /// - Parameters:
  ///   - path: The file in the marketplace tree, for the error.
  ///   - bytes: The number of bytes of the file.
  /// - Throws: ``SnapshotError/tooManyFiles(path:limit:)`` or
  ///   ``SnapshotError/tooManyBytes(path:limit:)``.
  private mutating func count(file path: String, bytes: Int) throws {
    report.fileCount += 1
    report.byteCount += bytes
    guard report.fileCount <= limits.maxFiles else {
      throw SnapshotError.tooManyFiles(path: path, limit: limits.maxFiles)
    }
    guard report.byteCount <= limits.maxBytes else {
      throw SnapshotError.tooManyBytes(path: path, limit: limits.maxBytes)
    }
  }

  // MARK: - Diagnostics

  /// Records that one tree path wrote one snapshot path.
  ///
  /// A second write of the same snapshot path is a partial of two folders.
  /// The later one wins, and the call records one warning.
  ///
  /// - Parameters:
  ///   - treePath: The item in the marketplace tree.
  ///   - relativePath: The item in the snapshot, relative to
  ///     ``destination``.
  private mutating func note(write treePath: String, toRelativePath relativePath: String) {
    guard let earlier = writtenPaths.updateValue(treePath, forKey: relativePath) else {
      return
    }
    let message =
      #"Two folders give "\#(relativePath)": "\#(earlier)" and "\#(treePath)". The snapshot uses "\#(treePath)"."#
    report.diagnostics.append(diagnostic(saying: message))
  }

  /// Forgets each write into the partials folder of the snapshot.
  ///
  /// The next write of such a path comes from a more specific folder. It
  /// replaces the earlier copy, which is the rule of the merge, thus it
  /// gives no diagnostic.
  private mutating func forgetPartialsWrites() {
    let prefix = partialsDirectoryName + String(CatalogPath.separator)
    writtenPaths = writtenPaths.filter { !$0.key.hasPrefix(prefix) }
  }

  /// Records that one file holds a large file storage pointer.
  ///
  /// The writer writes the pointer as it is, because the content is in
  /// another store that the writer does not read.
  ///
  /// - Parameters:
  ///   - path: The file in the marketplace tree.
  ///   - data: The bytes of the file.
  private mutating func notePointer(file path: String, data: Data) {
    let prefix = Data(SnapshotWriter.largeFileStoragePrefix.utf8)
    guard data.starts(with: prefix) else {
      return
    }
    let message =
      #"The file "\#(path)" is a large file storage pointer, not the content. The snapshot holds the pointer."#
    report.diagnostics.append(diagnostic(saying: message))
  }

  /// Makes one warning about this marketplace.
  ///
  /// - Parameter message: The text of the diagnostic.
  /// - Returns: The diagnostic, with ``marketplaceID``.
  private func diagnostic(saying message: String) -> MarketplaceDiagnostic {
    MarketplaceDiagnostic(severity: .warning, marketplaceID: marketplaceID, message: message)
  }

  // MARK: - Names and paths

  /// The location of one item of the snapshot.
  ///
  /// The call appends one checked component at a time, so it never puts a
  /// separator of the tree into the path.
  ///
  /// - Parameter relativePath: The item, relative to ``destination``.
  /// - Returns: The location on the disk.
  private func url(forRelativePath relativePath: String) -> URL {
    relativePath.split(separator: CatalogPath.separator)
      .reduce(destination) { $0.appendingPathComponent(String($1)) }
  }

  /// Removes the item that an earlier write put at `url`, so that a later
  /// copy replaces it.
  ///
  /// A later file never writes through an earlier symbolic link into the
  /// target of that link, and a later link never fails on an earlier file.
  /// The check reads the item itself, not the target of a link, thus a
  /// link to a file that is not there is removed too.
  ///
  /// - Parameter url: The location of the item in the snapshot.
  /// - Throws: The error of the removal.
  private static func removeEarlierItem(at url: URL) throws {
    guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
      return
    }
    try FileManager.default.removeItem(at: url)
  }

  /// Checks one name before it becomes a component of a snapshot path.
  ///
  /// This is the rule of ``MarketplaceCache``: a name that is empty, that
  /// holds a separator, or that holds a control character can leave the
  /// folder that holds it. A name that holds `..`, and the name `.`, walk
  /// out of a folder or name the folder itself.
  ///
  /// - Parameters:
  ///   - name: The name to check. It is one name, not a path.
  ///   - directory: The folder in the tree that holds the name, for the
  ///     error.
  /// - Returns: The name, which is now safe in a path.
  /// - Throws: ``SnapshotError/unsafeEntryName(directory:name:)``.
  private static func validated(name: String, inDirectory directory: String) throws -> String {
    guard !name.isEmpty,
      name != currentDirectoryName,
      !name.contains(parentDirectoryName),
      !name.contains(where: nameSeparators.contains),
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw SnapshotError.unsafeEntryName(directory: directory, name: name)
    }
    return name
  }

  /// Whether a symbolic link target stays in the skill folder that holds
  /// the link.
  ///
  /// The call walks the components of the target and counts the levels
  /// below the root of the skill folder. A target that reaches a level
  /// below zero leaves the folder. The call reads no file, so a link to a
  /// file that is not there gives the same answer.
  ///
  /// - Parameters:
  ///   - depth: How many levels the folder that holds the link is under the
  ///     root of its skill folder.
  ///   - target: The path that the link points to.
  /// - Returns: `true` when the target stays in the skill folder.
  private static func stays(inFolderAtDepth depth: Int, target: String) -> Bool {
    guard !absolutePathPrefixes.contains(where: target.hasPrefix) else {
      return false
    }
    var level = depth
    for component in target.split(separator: CatalogPath.separator) {
      switch component {
      case Substring(parentDirectoryName):
        level -= 1
      case Substring(currentDirectoryName):
        continue
      default:
        level += 1
      }
      guard level >= shallowestLinkLevel else {
        return false
      }
    }
    return true
  }

  // MARK: - The partials folders

  /// The folders whose partials folder the snapshot copies, each one time,
  /// in catalog order.
  ///
  /// For each source root, the list holds the root, then each folder from
  /// the root down to the folder that holds each skill of that root. A
  /// skill with no source root above it walks from the root of the tree.
  /// The walk stops above the skill folder, because a partials folder
  /// inside a skill folder goes with the skill folder.
  ///
  /// - Parameters:
  ///   - roots: The source roots, in catalog order.
  ///   - skills: The selected skills, in catalog order.
  /// - Returns: The folders, with no repeat.
  private static func partialsFolders(ofSourceRoots roots: [String], skills: [ResolvedSkill]) -> [String] {
    let walks = skills.map { skill in
      let root = sourceRoot(of: skill.path, among: roots) ?? treeRoot
      return (root: root, folders: folders(from: root, downTo: CatalogPath.parent(of: skill.path)))
    }
    let rootWalks = roots.flatMap { root in [root] + walks.filter { $0.root == root }.flatMap(\.folders) }
    let otherWalks = walks.filter { !roots.contains($0.root) }.flatMap(\.folders)
    var seen: Set<String> = []
    return (rootWalks + otherWalks).filter { seen.insert($0).inserted }
  }

  /// Groups folders by their level of specificity.
  ///
  /// - Parameter folders: The folders, in catalog order.
  /// - Returns: One group for each number of path components, from the
  ///   fewest to the most. Each group keeps the catalog order.
  private static func specificityLevels(of folders: [String]) -> [[String]] {
    Dictionary(grouping: folders, by: depth(of:)).sorted { $0.key < $1.key }.map(\.value)
  }

  /// The most specific source root that holds a path.
  ///
  /// - Parameters:
  ///   - path: The path of a skill folder in the tree.
  ///   - roots: The source roots.
  /// - Returns: The source root with the most path components that is the
  ///   path itself or a folder above it, or `nil` when no root holds the
  ///   path.
  private static func sourceRoot(of path: String, among roots: [String]) -> String? {
    let components = path.split(separator: CatalogPath.separator)
    return roots.filter { components.starts(with: $0.split(separator: CatalogPath.separator)) }
      .max { depth(of: $0) < depth(of: $1) }
  }

  /// Each folder from one folder down to a folder below it.
  ///
  /// - Parameters:
  ///   - root: The first folder of the walk.
  ///   - folder: The last folder of the walk. It is `root`, or a folder
  ///     below `root`.
  /// - Returns: The folders, from `root` to `folder`, or no folder when
  ///   `folder` is above `root`.
  private static func folders(from root: String, downTo folder: String) -> [String] {
    let components = folder.split(separator: CatalogPath.separator)
    let rootDepth = depth(of: root)
    guard components.count >= rootDepth else {
      return []
    }
    return (rootDepth...components.count).map {
      components.prefix($0).joined(separator: String(CatalogPath.separator))
    }
  }

  /// The number of path components of a folder: its level of specificity.
  ///
  /// - Parameter path: The normalized path. The empty path is the root.
  /// - Returns: The number of components. The root gives zero.
  private static func depth(of path: String) -> Int {
    path.split(separator: CatalogPath.separator).count
  }
}
