import Foundation
import Synchronization

/// A value that the cache puts into a file path.
internal enum MarketplacePathValue: String, Sendable {
  /// The commit of a snapshot. It names a folder under `snapshots/`, and it
  /// is the target of the `current` symlink.
  case sha

  /// The branch or the tag. It names a file under `refs/`.
  case ref
}

/// Why the cache cannot finish a file operation (marketplace.md §7).
internal enum MarketplaceCacheError: Error, Equatable, Sendable {
  /// The cache cannot open or lock a file. The path names the file, and the
  /// code is the `errno` of the call.
  case cannotLock(path: String, code: Int32)

  /// Another writer holds the folder of the marketplace now, thus the call
  /// did no work at all. The path names the lock file.
  ///
  /// The writer lock never waits (marketplace.md §7.6): a wait would hold
  /// the thread of the actor, and the holder of the lock may need that same
  /// actor to finish its own work. The caller keeps the snapshot it serves
  /// and runs again later.
  case writerLockHeld(path: String)

  /// The cache cannot put the new `current` symlink in place. The path names
  /// the symlink, and the code is the `errno` of `rename(2)`.
  case cannotSwap(path: String, code: Int32)

  /// A value cannot go into a cache path, because one of its name
  /// components is empty, starts with a dot, or holds a backslash or a
  /// control character.
  case unsafePathValue(kind: MarketplacePathValue, value: String)

  /// A value is no commit, because it is not a hexadecimal object name.
  case notACommit(value: String)

  /// The folder holds no snapshot of that commit, thus `current` cannot
  /// name it. Cleanup in another process deletes a snapshot that no reader
  /// holds, so a staged snapshot can be gone before a later launch serves
  /// it.
  case snapshotMissing(sha: String)
}

extension MarketplaceCacheError: CustomStringConvertible {
  /// A sentence that tells the file and the error code.
  var description: String {
    switch self {
    case .cannotLock(let path, let code):
      #"Cannot lock "\#(path)": error code \#(code)."#
    case .writerLockHeld(let path):
      #"Another writer holds the marketplace folder of "\#(path)" now."#
    case .cannotSwap(let path, let code):
      #"Cannot put the new snapshot link "\#(path)" in place: error code \#(code)."#
    case .unsafePathValue(let kind, let value):
      #"The \#(kind.rawValue) "\#(value)" cannot go into a cache path."#
    case .notACommit(let value):
      #"The sha "\#(value)" is no commit."#
    case .snapshotMissing(let sha):
      #"The cache holds no snapshot of the commit "\#(sha)"."#
    }
  }
}

/// The on-disk cache of one marketplace (marketplace.md §7.1, §7.2, §7.3, and
/// §7.6).
///
/// The cache does no network work. A caller fetches and materializes a
/// snapshot in a folder of its own, and then gives that folder to
/// ``install(snapshotAt:sha:ref:)``. The install puts the folder under
/// `snapshots/`, writes the ref file, and swaps the `current` symlink in one
/// `rename(2)`. Thus a reader sees the old snapshot or the new snapshot, and
/// never a folder that is half written.
///
/// ```
/// <cache>/
/// ├── state.json
/// └── <folderName>/
///     ├── repo.git/
///     ├── refs/<ref>
///     ├── snapshots/<sha>/
///     ├── current -> snapshots/<sha>
///     └── lock
/// ```
internal struct MarketplaceCache: Sendable {
  // MARK: - Names

  /// The environment variable that names the cache directory.
  static let cacheVariable = "SKILLS_MARKETPLACE_CACHE"

  /// The environment variable that names the read-only seed folder
  /// (marketplace.md §7.5).
  static let seedVariable = "SKILLS_MARKETPLACE_SEED"

  /// The cache directory under the home folder, for an environment that
  /// does not name one.
  private static let homeCachePath = ".cache/skills/marketplaces"

  /// The name of the bare repository folder of one marketplace.
  private static let repositoryDirectoryName = "repo.git"

  /// The name of the folder that holds one file for each ref.
  private static let refsDirectoryName = "refs"

  /// The name of the folder that holds one folder for each snapshot.
  private static let snapshotsDirectoryName = "snapshots"

  /// The name of the symlink that names the snapshot the consumer reads.
  private static let currentLinkName = "current"

  /// The name of the symlink that the swap makes before it renames the link
  /// over ``currentLinkName``.
  private static let stagedLinkName = "current.new"

  /// The name of the file that the writer lock holds.
  private static let lockFileName = "lock"

  /// The permissions of the lock file. Only the owner writes it.
  private static let lockFileMode: mode_t = 0o644

  /// The `open(2)` flags that keep a lock descriptor out of each child
  /// process. Each open that takes a `flock(2)` lock adds them.
  ///
  /// `flock(2)` belongs to the open file description, thus a copy of the
  /// descriptor in a child process keeps the lock alive after this process
  /// closes its own descriptor. The host can start a child process at any
  /// moment.
  ///
  /// - `O_CLOEXEC` closes the descriptor at the exec step of a child. This
  ///   alone is not sufficient: `posix_spawn` copies the descriptor table at
  ///   its fork step and closes the close-on-exec entries later, at its exec
  ///   step. Between the two steps the new process holds the lock. A
  ///   `close(2)` in this process during that window does not release the
  ///   lock, and the next `LOCK_NB` request finds the file locked.
  /// - `O_CLOFORK` tells the kernel not to copy the descriptor at the fork
  ///   step at all, thus that window does not exist.
  static let noInheritanceOpenFlags = O_CLOEXEC | O_CLOFORK

  // MARK: - Safe values in a path

  /// The characters of a hexadecimal object name.
  private static let hexDigits = Set("0123456789abcdefABCDEF")

  /// The number of hex digits of a SHA-1 object name.
  private static let sha1Length = 40

  /// The number of hex digits of a SHA-256 object name.
  private static let sha256Length = 64

  /// The lengths that the object name of a commit can have.
  private static let commitLengths: Set<Int> = [sha1Length, sha256Length]

  /// The character that separates the name components of a ref.
  private static let refSeparator: Character = "/"

  /// The characters that make one name component more than one name.
  private static let pathSeparators: Set<Character> = [refSeparator, "\\"]

  /// The character that starts a hidden name.
  private static let hiddenNamePrefix = "."

  /// Whether one name component is safe inside the cache folder
  /// (marketplace.md §7.2).
  ///
  /// A component that is empty, that starts with a dot, that holds a
  /// separator, or that holds a control character, can leave the cache
  /// folder. A component that starts with a dot covers `.` and `..`, which
  /// are the two names that walk out of a folder.
  ///
  /// - Parameter component: The one name to check.
  /// - Returns: `true` when the name stays inside the folder that holds it.
  private static func isSafe(component: String) -> Bool {
    !component.isEmpty
      && !component.hasPrefix(hiddenNamePrefix)
      && !component.contains(where: pathSeparators.contains)
      && !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  /// Checks a value that names one file or folder of the cache
  /// (marketplace.md §7.2).
  ///
  /// - Parameters:
  ///   - value: The value to check. It is one name, not a path.
  ///   - kind: What the value names. The error tells it.
  /// - Returns: The value, which is now safe in a path.
  /// - Throws: ``MarketplaceCacheError/unsafePathValue(kind:value:)`` when
  ///   the value can leave the cache folder.
  static func validated(pathValue value: String, kind: MarketplacePathValue) throws -> String {
    guard isSafe(component: value) else {
      throw MarketplaceCacheError.unsafePathValue(kind: kind, value: value)
    }
    return value
  }

  /// Checks a commit before it names a snapshot folder or a symlink target.
  ///
  /// A commit is a hexadecimal object name, so it is safe in a path and it
  /// holds no separator. The call proves both.
  ///
  /// - Parameter sha: The commit to check.
  /// - Returns: The commit, which is now safe in a path.
  /// - Throws: ``MarketplaceCacheError/unsafePathValue(kind:value:)`` or
  ///   ``MarketplaceCacheError/notACommit(value:)``.
  static func validated(sha: String) throws -> String {
    let value = try validated(pathValue: sha, kind: .sha)
    guard commitLengths.contains(value.count), value.allSatisfy(hexDigits.contains) else {
      throw MarketplaceCacheError.notACommit(value: value)
    }
    return value
  }

  /// Checks a branch or a tag before it names a file under `refs/`.
  ///
  /// Git permits a `/` in a ref name, as in `feature/login` and
  /// `refs/heads/main`, and each part is then one folder under `refs/`. So
  /// the call splits the ref on `/` and checks each part with the rule for
  /// one name. A leading `/`, a trailing `/`, and two separators together
  /// all make an empty part, which the rule refuses; thus the ref stays
  /// inside the folder of the marketplace.
  ///
  /// - Parameter ref: The branch or the tag to check.
  /// - Returns: The name components of the ref, in order, each one safe in
  ///   a path.
  /// - Throws: ``MarketplaceCacheError/unsafePathValue(kind:value:)`` when
  ///   the ref can leave the cache folder.
  static func validated(ref: String) throws -> [String] {
    let components = ref.split(separator: refSeparator, omittingEmptySubsequences: false)
      .map(String.init)
    guard components.allSatisfy(isSafe(component:)) else {
      throw MarketplaceCacheError.unsafePathValue(kind: .ref, value: ref)
    }
    return components
  }

  /// Whether a name is the object name of a commit.
  ///
  /// - Parameter name: The name to read, such as a folder name that the
  ///   file system gave.
  /// - Returns: `true` when the name is a commit that is safe in a path.
  private static func isCommit(name: String) -> Bool {
    (try? validated(sha: name)) != nil
  }

  // MARK: - Location

  /// The cache directory that `environment` names (marketplace.md §7.1).
  ///
  /// The variable when it is set and not empty, else the standard folder
  /// under the home folder. The call is a pure function of the environment,
  /// so a test gives its own.
  ///
  /// - Parameter environment: The environment to read.
  /// - Returns: The cache directory.
  static func cacheDirectory(environment: [String: String]) -> URL {
    directory(ofVariable: cacheVariable, in: environment)
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(homeCachePath, isDirectory: true)
  }

  /// The read-only seed folder that `environment` names
  /// (marketplace.md §7.5).
  ///
  /// The folder has the layout of a cache directory. It gives an offline or
  /// a CI install: the store reads a snapshot from it, and never writes it.
  ///
  /// - Parameter environment: The environment to read.
  /// - Returns: The seed folder, or `nil` when `SKILLS_MARKETPLACE_SEED` is
  ///   not set or is empty.
  static func seedDirectory(environment: [String: String]) -> URL? {
    directory(ofVariable: seedVariable, in: environment)
  }

  /// The folder that one environment variable names.
  ///
  /// - Parameters:
  ///   - name: The variable to read.
  ///   - environment: The environment to read.
  /// - Returns: The folder, with a leading `~` expanded, or `nil` when the
  ///   variable is not set or is empty.
  private static func directory(ofVariable name: String, in environment: [String: String]) -> URL? {
    guard let configured = environment[name], !configured.isEmpty else {
      return nil
    }
    return URL(
      fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
  }

  /// The state file of a cache directory.
  ///
  /// - Parameter root: The cache directory.
  /// - Returns: `<root>/state.json`.
  static func stateFile(inCacheDirectory root: URL) -> URL {
    root.appendingPathComponent(MarketplaceState.fileName)
  }

  // MARK: - The folder of one marketplace

  /// The cache directory that holds `state.json` and every marketplace
  /// folder.
  let root: URL

  /// The folder name of this marketplace, from
  /// ``MarketplaceIdentity/cacheFolderName(key:normalizedURL:)``.
  let folderName: String

  /// The folder of this marketplace: `<root>/<folderName>`.
  var folder: URL {
    root.appendingPathComponent(folderName, isDirectory: true)
  }

  /// The bare repository that the fetch writes.
  var repositoryDirectory: URL {
    folder.appendingPathComponent(Self.repositoryDirectoryName, isDirectory: true)
  }

  /// The folder that holds one file for each ref.
  var refsDirectory: URL {
    folder.appendingPathComponent(Self.refsDirectoryName, isDirectory: true)
  }

  /// The folder that holds one folder for each snapshot.
  var snapshotsDirectory: URL {
    folder.appendingPathComponent(Self.snapshotsDirectoryName, isDirectory: true)
  }

  /// The symlink that names the snapshot the consumer reads.
  ///
  /// The URL says that it names a folder, thus its path ends in `/` and a
  /// directory read follows the link. A URL with no trailing `/` makes
  /// `FileManager.contentsOfDirectory(at:…)` open the link itself, which is
  /// not a folder.
  var currentLink: URL {
    folder.appendingPathComponent(Self.currentLinkName, isDirectory: true)
  }

  /// The file that the writer lock holds.
  var lockFile: URL {
    folder.appendingPathComponent(Self.lockFileName)
  }

  /// The folder of one snapshot.
  ///
  /// - Parameter sha: The commit of the snapshot.
  /// - Returns: `<folder>/snapshots/<sha>`.
  /// - Throws: ``MarketplaceCacheError`` when `sha` is no commit that is
  ///   safe in a path.
  func snapshotDirectory(forSha sha: String) throws -> URL {
    snapshotDirectory(forValidatedSha: try Self.validated(sha: sha))
  }

  /// The folder of one snapshot whose commit ``validated(sha:)`` already
  /// checked.
  ///
  /// - Parameter sha: The checked commit of the snapshot.
  /// - Returns: `<folder>/snapshots/<sha>`.
  private func snapshotDirectory(forValidatedSha sha: String) -> URL {
    snapshotsDirectory.appendingPathComponent(sha, isDirectory: true)
  }

  /// The file of one ref whose components ``validated(ref:)`` already
  /// checked.
  ///
  /// The call appends one component at a time, so it never puts a separator
  /// of the caller into the path.
  ///
  /// - Parameter components: The checked name components of the ref.
  /// - Returns: `<folder>/refs/<component>/…/<component>`.
  private func refFile(forValidatedRef components: [String]) -> URL {
    components.reduce(refsDirectory) { $0.appendingPathComponent($1) }
  }

  // MARK: - Reading

  /// The commit that `current` names.
  ///
  /// The symlink is a file that another program can write, so the call
  /// checks its target in the same way as a value of a caller.
  ///
  /// - Returns: The commit, or `nil` when there is no `current` symlink, or
  ///   when the target of the symlink is no commit.
  func currentSha() -> String? {
    guard
      let target = try? FileManager.default.destinationOfSymbolicLink(
        atPath: currentLink.path),
      let sha = try? Self.validated(sha: (target as NSString).lastPathComponent)
    else {
      return nil
    }
    return sha
  }

  /// The snapshot folder that `current` names.
  ///
  /// - Returns: The folder, or `nil` when there is no `current` symlink, or
  ///   when the target of the symlink is no commit.
  func currentSnapshot() -> URL? {
    currentSha().map { snapshotDirectory(forValidatedSha: $0) }
  }

  /// The commits of the snapshots that the folder holds, in order.
  ///
  /// A name that is no commit is not a snapshot, so the call drops it and
  /// cleanup never deletes it.
  ///
  /// - Returns: The commits, or an empty list before the first install.
  /// - Throws: The error of the folder read.
  func installedShas() throws -> [String] {
    let manager = FileManager.default
    guard manager.fileExists(atPath: snapshotsDirectory.path) else {
      return []
    }
    return try manager.contentsOfDirectory(atPath: snapshotsDirectory.path)
      .filter { Self.isCommit(name: $0) }
      .sorted()
  }

  /// The commit that a ref file names.
  ///
  /// - Parameter ref: The branch or the tag.
  /// - Returns: The commit, or `nil` when there is no file for that ref.
  /// - Throws: ``MarketplaceCacheError`` when `ref` is not safe in a path,
  ///   else the error of the file read.
  func sha(forRef ref: String) throws -> String? {
    let file = refFile(forValidatedRef: try Self.validated(ref: ref))
    guard FileManager.default.fileExists(atPath: file.path) else {
      return nil
    }
    return try String(contentsOf: file, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Installing

  /// Puts a materialized snapshot in place and makes `current` name it
  /// (marketplace.md §7.3 steps 5 to 7).
  ///
  /// The whole call holds the writer lock, so one writer works on the folder
  /// at a time, also across processes. The steps are: move the staged folder
  /// to `snapshots/<sha>`, write `refs/<ref>`, make the `current.new`
  /// symlink and rename it over `current`, then clean up.
  ///
  /// The call checks `sha` and `ref` before it makes one folder, so a value
  /// that can leave the cache folder writes nothing at all.
  ///
  /// - Parameters:
  ///   - temporary: The folder that holds the materialized snapshot. The
  ///     call moves it, so the caller must not read it afterwards. It must
  ///     be on the same volume as the cache.
  ///   - sha: The commit of the snapshot.
  ///   - ref: The branch or the tag that resolved to `sha`, or `nil` for a
  ///     pinned commit, which has no ref file.
  /// - Throws: ``MarketplaceCacheError`` when the lock or the swap fails,
  ///   else the error of the file work.
  func install(snapshotAt temporary: URL, sha: String, ref: String?) throws {
    let checked = try Self.validated(sha: sha, ref: ref)
    try makeFolders()
    try withWriterLock {
      try installValidated(snapshotAt: temporary, checked: checked)
    }
  }

  /// The same work as ``install(snapshotAt:sha:ref:)``, for a caller that
  /// already made the folders and already holds the writer lock.
  ///
  /// The store holds the lock over the whole sync of one marketplace, which
  /// covers the fetch and the materialize as well as the swap
  /// (marketplace.md §7.6). `flock(2)` is per open file, thus a second lock
  /// of the same file from the same process would wait forever; this entry
  /// point takes no lock of its own.
  ///
  /// - Parameters:
  ///   - temporary: The folder that holds the materialized snapshot.
  ///   - sha: The commit of the snapshot.
  ///   - ref: The branch or the tag that resolved to `sha`, or `nil` for a
  ///     pinned commit.
  /// - Throws: ``MarketplaceCacheError`` when a value is not safe in a path
  ///   or the swap fails, else the error of the file work.
  func installUnderWriterLock(snapshotAt temporary: URL, sha: String, ref: String?) throws {
    try installValidated(snapshotAt: temporary, checked: try Self.validated(sha: sha, ref: ref))
  }

  /// Checks the commit and the ref of one install.
  ///
  /// - Parameters:
  ///   - sha: The commit of the snapshot.
  ///   - ref: The branch or the tag, or `nil` for a pinned commit.
  /// - Returns: The commit, and the name components of the ref.
  /// - Throws: ``MarketplaceCacheError`` when a value can leave the cache
  ///   folder.
  private static func validated(sha: String, ref: String?) throws -> (sha: String, ref: [String]?) {
    (sha: try validated(sha: sha), ref: try ref.map { try validated(ref: $0) })
  }

  /// Runs the steps of one install over values that are already checked,
  /// under a writer lock that the caller holds.
  ///
  /// - Parameters:
  ///   - temporary: The folder that holds the materialized snapshot.
  ///   - checked: The checked commit and ref.
  /// - Throws: ``MarketplaceCacheError`` when the swap fails, else the
  ///   error of the file work.
  private func installValidated(snapshotAt temporary: URL, checked: (sha: String, ref: [String]?)) throws {
    try publish(snapshotAt: temporary, validatedSha: checked.sha)
    try activate(checked: checked)
  }

  /// Writes the ref file, makes `current` name one snapshot that is already
  /// under `snapshots/`, and then cleans up.
  ///
  /// - Parameter checked: The checked commit and ref.
  /// - Throws: ``MarketplaceCacheError`` when the swap fails, else the
  ///   error of the file work.
  private func activate(checked: (sha: String, ref: [String]?)) throws {
    let previous = currentSha()
    if let ref = checked.ref {
      try write(sha: checked.sha, toValidatedRef: ref)
    }
    try swapCurrent(toValidatedSha: checked.sha)
    try removeUnusedSnapshots(keeping: [checked.sha, previous].compactMap { $0 })
  }

  /// Puts a materialized snapshot under `snapshots/<sha>` and leaves
  /// `current` where it is (marketplace.md §8.4).
  ///
  /// This is the install of a host that applies an update at the next
  /// launch: the content is on the disk, and ``adopt(snapshotSha:ref:)``
  /// serves it later. The caller holds the writer lock and has made the
  /// folders.
  ///
  /// - Parameters:
  ///   - temporary: The folder that holds the materialized snapshot. The
  ///     call moves it, thus the caller must not read it afterwards.
  ///   - sha: The commit of the snapshot.
  ///   - kept: The commits that cleanup keeps beside `sha`: the snapshot
  ///     that `current` names, and the one before it.
  /// - Throws: ``MarketplaceCacheError`` when `sha` is no commit that is
  ///   safe in a path, else the error of the file work.
  func stageUnderWriterLock(snapshotAt temporary: URL, sha: String, keeping kept: [String]) throws {
    let checked = try Self.validated(sha: sha)
    try publish(snapshotAt: temporary, validatedSha: checked)
    try removeUnusedSnapshots(keeping: kept + [checked])
  }

  /// Makes `current` name a snapshot that the folder already holds
  /// (marketplace.md §8.4).
  ///
  /// ``stageUnderWriterLock(snapshotAt:sha:keeping:)`` put that folder
  /// there, possibly in an earlier run of the host. The call takes the
  /// writer lock itself.
  ///
  /// The test of the snapshot folder is inside the lock, in the same
  /// critical section as the swap. Cleanup in another process takes the
  /// same lock, thus it cannot delete the folder between the test and the
  /// swap, and `current` never names a folder that is gone. Only
  /// ``makeFolders()`` stays outside the lock, because the lock file lives
  /// in the folder that call makes.
  ///
  /// - Parameters:
  ///   - sha: The commit of the snapshot to serve.
  ///   - ref: The branch or the tag that resolved to `sha`, or `nil` for a
  ///     pinned commit, which has no ref file.
  /// - Throws: ``MarketplaceCacheError/snapshotMissing(sha:)`` when the
  ///   folder holds no snapshot of that commit, and `current` then stays
  ///   where it was; ``MarketplaceCacheError`` when a value is not safe in
  ///   a path or the swap fails; else the error of the file work.
  func adopt(snapshotSha sha: String, ref: String?) throws {
    let checked = try Self.validated(sha: sha, ref: ref)
    try makeFolders()
    try withWriterLock {
      let directory = snapshotDirectory(forValidatedSha: checked.sha)
      guard FileManager.default.fileExists(atPath: directory.path) else {
        throw MarketplaceCacheError.snapshotMissing(sha: checked.sha)
      }
      try activate(checked: checked)
    }
  }

  /// Makes the folders that an install writes into.
  ///
  /// A caller that takes the writer lock itself calls this first: the lock
  /// file lives in the folder of the marketplace.
  ///
  /// - Throws: The error of the folder.
  func makeFolders() throws {
    for directory in [folder, refsDirectory, snapshotsDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  /// Moves the staged folder to `snapshots/<sha>`.
  ///
  /// A snapshot that is already there holds the same commit, and the content
  /// of a commit never changes. Thus the call drops the staged copy and
  /// keeps the folder that readers may already hold open.
  ///
  /// - Parameters:
  ///   - temporary: The staged folder.
  ///   - sha: The checked commit of the snapshot.
  /// - Throws: The error of the move or of the delete.
  private func publish(snapshotAt temporary: URL, validatedSha sha: String) throws {
    let manager = FileManager.default
    let destination = snapshotDirectory(forValidatedSha: sha)
    guard !manager.fileExists(atPath: destination.path) else {
      try manager.removeItem(at: temporary)
      return
    }
    try manager.moveItem(at: temporary, to: destination)
  }

  /// Writes the commit that a ref resolved to.
  ///
  /// A ref name with a `/` in it gets one folder for each part before the
  /// last, so the call makes those folders before it writes the file.
  ///
  /// - Parameters:
  ///   - sha: The commit.
  ///   - ref: The checked name components of the branch or the tag.
  /// - Throws: The error of the folder or of the file write.
  private func write(sha: String, toValidatedRef ref: [String]) throws {
    let file = refFile(forValidatedRef: ref)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try sha.write(to: file, atomically: true, encoding: .utf8)
  }

  /// Makes `current` name one snapshot, in one atomic step.
  ///
  /// The call makes a second symlink and renames it over `current`, because
  /// `rename(2)` replaces the name in one operation. Deleting `current` and
  /// making it again would give a reader a window with no link.
  ///
  /// - Parameter sha: The checked commit of the snapshot. The target of the
  ///   symlink holds it, so only a checked value goes in.
  /// - Throws: ``MarketplaceCacheError/cannotSwap(path:code:)`` when the
  ///   rename fails, else the error of the symlink.
  private func swapCurrent(toValidatedSha sha: String) throws {
    let manager = FileManager.default
    let staged = folder.appendingPathComponent(Self.stagedLinkName)
    // A link that an interrupted install left behind is not an error.
    try? manager.removeItem(at: staged)
    try manager.createSymbolicLink(
      atPath: staged.path,
      withDestinationPath: "\(Self.snapshotsDirectoryName)/\(sha)")
    guard rename(staged.path, currentLink.path) == 0 else {
      throw MarketplaceCacheError.cannotSwap(path: currentLink.path, code: errno)
    }
  }

  // MARK: - Cleanup

  /// Deletes every snapshot that the keep list does not name and that no
  /// reader holds (marketplace.md §7.6).
  ///
  /// Cleanup counts; it reads no age and no time. The keep list holds the
  /// snapshot that `current` names and the one before it, for rollback.
  ///
  /// - Parameter kept: The commits to keep.
  /// - Throws: The error of the folder read or of a delete.
  private func removeUnusedSnapshots(keeping kept: [String]) throws {
    let keptShas = Set(kept)
    for sha in try installedShas() where !keptShas.contains(sha) {
      try removeSnapshot(validatedSha: sha)
    }
  }

  /// Deletes one snapshot, unless a reader holds a shared lock on it.
  ///
  /// - Parameter sha: The checked commit of the snapshot, which
  ///   ``installedShas()`` gave.
  /// - Throws: The error of the delete.
  private func removeSnapshot(validatedSha sha: String) throws {
    let directory = snapshotDirectory(forValidatedSha: sha)
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | Self.noInheritanceOpenFlags)
    guard descriptor >= 0 else {
      // Another writer of the same cache already deleted the folder.
      return
    }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      // A reader is using this snapshot. It stays until the next
      // cleanup.
      return
    }
    try FileManager.default.removeItem(at: directory)
  }

  // MARK: - Locks

  /// Runs `body` while this process holds the exclusive writer lock of the
  /// marketplace folder (marketplace.md §7.6).
  ///
  /// The call never waits for the lock: a folder that another writer holds
  /// gives ``MarketplaceCacheError/writerLockHeld(path:)`` and `body` does
  /// not run at all. ``openWriterLock()`` tells why.
  ///
  /// - Parameter body: The work to do under the lock.
  /// - Returns: What `body` gives.
  /// - Throws: ``MarketplaceCacheError/writerLockHeld(path:)`` when another
  ///   writer holds the folder, ``MarketplaceCacheError/cannotLock(path:code:)``
  ///   when the lock fails, else what `body` throws.
  func withWriterLock<Value>(_ body: () throws -> Value) throws -> Value {
    let descriptor = try openWriterLock()
    defer { close(descriptor) }
    return try body()
  }

  /// Runs an asynchronous `body` while this process holds the exclusive
  /// writer lock of the marketplace folder (marketplace.md §7.6).
  ///
  /// The store holds the lock over the whole sync of one marketplace, and
  /// the fetch in the middle of that sync is asynchronous. `flock(2)`
  /// belongs to the open file, not to the thread, thus the lock stays over
  /// a suspension point.
  ///
  /// The call never waits for the lock: a folder that another writer holds
  /// gives ``MarketplaceCacheError/writerLockHeld(path:)`` and `body` does
  /// not run at all. ``openWriterLock()`` tells why.
  ///
  /// The folder of the marketplace must exist: ``makeFolders()`` makes it.
  ///
  /// - Parameters:
  ///   - isolation: The actor that the caller runs on, so that `body` can
  ///     read the state of that actor. The default is the caller.
  ///   - body: The work to do under the lock.
  /// - Returns: What `body` gives.
  /// - Throws: ``MarketplaceCacheError/writerLockHeld(path:)`` when another
  ///   writer holds the folder, ``MarketplaceCacheError/cannotLock(path:code:)``
  ///   when the lock fails, else what `body` throws.
  func withWriterLock<Value>(
    isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> Value
  ) async throws -> Value {
    let descriptor = try openWriterLock()
    defer { close(descriptor) }
    return try await body()
  }

  /// Opens the lock file and takes the exclusive writer lock, without a
  /// wait.
  ///
  /// The lock is `LOCK_NB`, thus a folder that another writer holds gives
  /// ``MarketplaceCacheError/writerLockHeld(path:)`` at once. A wait would
  /// be a deadlock: `flock(2)` belongs to the open file description, so a
  /// second open of the same file conflicts with the first one even inside
  /// one process, and the wait holds the thread. `MarketplaceStore` is an
  /// actor that holds this lock over the `await` of its fetch, thus the
  /// waiting call would hold the very actor that the holder needs to
  /// finish and release the lock.
  ///
  /// The call reads `errno` before it closes the descriptor, because
  /// `close(2)` can replace the value.
  ///
  /// - Returns: The open descriptor. The caller closes it, which releases
  ///   the lock.
  /// - Throws: ``MarketplaceCacheError/writerLockHeld(path:)`` when another
  ///   writer holds the folder, else
  ///   ``MarketplaceCacheError/cannotLock(path:code:)``.
  private func openWriterLock() throws -> Int32 {
    let descriptor = open(
      lockFile.path, O_CREAT | O_RDWR | Self.noInheritanceOpenFlags, Self.lockFileMode)
    guard descriptor >= 0 else {
      throw MarketplaceCacheError.cannotLock(path: lockFile.path, code: errno)
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      throw code == EWOULDBLOCK
        ? MarketplaceCacheError.writerLockHeld(path: lockFile.path)
        : MarketplaceCacheError.cannotLock(path: lockFile.path, code: code)
    }
    return descriptor
  }

  /// Runs `body` while this process holds a shared lock on one snapshot, so
  /// that cleanup does not delete the folder the caller is reading.
  ///
  /// - Parameters:
  ///   - sha: The commit of the snapshot.
  ///   - body: The work to do with the snapshot folder.
  /// - Returns: What `body` gives.
  /// - Throws: ``MarketplaceCacheError`` when `sha` is no commit, when the
  ///   folder does not open, or when the lock fails, else what `body`
  ///   throws.
  func withSnapshotInUse<Value>(sha: String, _ body: (URL) throws -> Value) throws -> Value {
    let directory = try snapshotDirectory(forSha: sha)
    let lease = try Self.sharedLock(onDirectory: directory)
    return try withExtendedLifetime(lease) { try body(directory) }
  }

  /// Takes a shared lock on the snapshot that `current` names, and keeps it
  /// until the caller releases the lease (marketplace.md §7.6).
  ///
  /// A store holds one lease for as long as it serves a snapshot, thus
  /// cleanup in another process keeps that folder.
  ///
  /// - Returns: The lease, or `nil` when there is no `current` snapshot.
  /// - Throws: ``MarketplaceCacheError/cannotLock(path:code:)`` when the
  ///   folder does not open or the lock fails.
  func leaseCurrentSnapshot() throws -> SnapshotLease? {
    guard let directory = currentSnapshot() else {
      return nil
    }
    return try Self.sharedLock(onDirectory: directory)
  }

  /// Takes a shared lock on one snapshot folder.
  ///
  /// The lock is on the folder itself, so the layer root gets no extra file
  /// that a reader of the layer root would see.
  ///
  /// The open adds ``noInheritanceOpenFlags``, which keep the descriptor out
  /// of each child process. Thus only ``SnapshotLease/releaseNow()`` in this
  /// process ends the lease, and it ends the lease at once.
  ///
  /// - Parameter directory: The snapshot folder.
  /// - Returns: The lease, which holds the lock until it is released.
  /// - Throws: ``MarketplaceCacheError/cannotLock(path:code:)``.
  private static func sharedLock(onDirectory directory: URL) throws -> SnapshotLease {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | noInheritanceOpenFlags)
    guard descriptor >= 0 else {
      throw MarketplaceCacheError.cannotLock(path: directory.path, code: errno)
    }
    guard flock(descriptor, LOCK_SH) == 0 else {
      close(descriptor)
      throw MarketplaceCacheError.cannotLock(path: directory.path, code: errno)
    }
    return SnapshotLease(descriptor: descriptor)
  }
}

/// A shared lock that one reader holds on the snapshot folder it serves
/// (marketplace.md §7.6).
///
/// The lock lasts as long as the lease. Cleanup, in this process or in
/// another one, takes an exclusive lock before it deletes a snapshot, thus it
/// never deletes a folder that a lease holds.
///
/// The only stored property is an immutable `let` of a `Mutex`, which gives
/// the class a plain `Sendable` conformance that the compiler checks.
internal final class SnapshotLease: Sendable {
  /// The open folder that holds the lock, or `nil` after the release.
  private let heldDirectory: Mutex<Int32?>

  /// Takes over an open, already locked folder.
  ///
  /// - Parameter descriptor: The open folder, with its shared lock.
  fileprivate init(descriptor: Int32) {
    heldDirectory = Mutex(descriptor)
  }

  /// Releases the lock now.
  ///
  /// A holder that replaces one lease with another calls this, thus the
  /// snapshot that it leaves is free for the next cleanup at that moment,
  /// and not when the last reference to the lease goes away. A second call
  /// does nothing.
  func releaseNow() {
    heldDirectory.withLock { held in
      if let descriptor = held {
        close(descriptor)
        held = nil
      }
    }
  }

  deinit {
    releaseNow()
  }
}
