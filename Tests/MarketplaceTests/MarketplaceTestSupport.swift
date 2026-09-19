import FixtureSupport
import Foundation

@testable import Marketplace

/// Records each URL that a credential provider gets.
///
/// `CredentialGateTests` and `GitTransportTests` both prove that a credential
/// provider is asked one time, and with which URL. Thus the recorder is here,
/// and not in one of the two suites.
actor CredentialRequestRecorder {
  /// The URL of each request, in order.
  private(set) var requestedURLs: [URL] = []

  /// Records one request.
  ///
  /// - Parameter url: The URL that the provider got.
  func record(url: URL) {
    requestedURLs.append(url)
  }

  /// Makes a provider that records each request and gives `credential`.
  ///
  /// - Parameter credential: The credential that the provider gives.
  /// - Returns: The provider.
  nonisolated func provider(giving credential: MarketplaceCredential) -> @Sendable (URL) async -> MarketplaceCredential? {
    { url in
      await self.record(url: url)
      return credential
    }
  }
}

/// The shared helpers of the marketplace tests.
///
/// `MarketplaceConfigTests` and `MarketplaceCacheTests` write text files into
/// a temporary folder with ``writeFile(text:to:)``. `MarketplaceCatalogTests`,
/// `GitTreeFileSourceTests` and `SnapshotWriterTests` resolve the fixture
/// catalogs with ``skillsLayout``, find them with ``catalogFixture(named:)``,
/// and write a small tree with ``makeTempDirectory(withFiles:)``.
///
/// The file helper does not call `MarketplaceConfig.save(to:)`, because that
/// is the code under test: a test that writes its fixture with the code it
/// proves can pass while both are wrong.
enum MarketplaceTestSupport {
  /// The layout of a skills marketplace: `SKILL.md` marks an entry folder.
  static let skillsLayout = MarketplaceLayout(documentName: "SKILL.md")

  /// The folder of the fixture catalogs, relative to the package root.
  private static let catalogFixturesPath = "Tests/MarketplaceTests/Fixtures/catalogs"

  /// Gives the folder of one fixture catalog.
  ///
  /// - Parameter name: The folder name of the fixture.
  /// - Returns: The folder, under the package root.
  static func catalogFixture(named name: String) -> URL {
    FixtureFile.url("\(catalogFixturesPath)/\(name)")
  }

  /// Makes a new temporary folder and writes a tree of text files into it.
  ///
  /// - Parameter files: The text of each file, keyed by its path in the
  ///   folder.
  /// - Returns: The new folder.
  /// - Throws: The error of a folder or file write.
  static func makeTempDirectory(withFiles files: [String: String]) throws -> URL {
    let root = try TemporaryDirectory.make()
    for (path, text) in files {
      try writeFile(text: text, to: root.appendingPathComponent(path))
    }
    return root
  }

  /// Writes text to a file, and makes the folder of the file first.
  ///
  /// - Parameters:
  ///   - text: The text of the file.
  ///   - file: The file to write.
  /// - Throws: The error of the folder or the file write.
  static func writeFile(text: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
  }
}

/// Tells whether a shared lock holds one snapshot folder (marketplace.md
/// §7.6).
///
/// `MarketplaceCacheTests` proves the lease itself, and a store test proves
/// which snapshot the store leases. Thus the probe is here, and not in one
/// suite.
enum SnapshotLockProbe {
  /// Whether a second open of one folder cannot take the exclusive lock.
  ///
  /// A `flock(2)` lock belongs to the open file and not to the process, thus
  /// a second open in this process sees the shared lock of a lease.
  ///
  /// - Parameter directory: The snapshot folder to test.
  /// - Returns: `true` when a lock holds the folder. A folder that does not
  ///   open gives `false`.
  static func isLocked(directory: URL) -> Bool {
    // The probe takes a lock, thus it opens the folder with the same flags
    // as the cache. A different test can start a child process while this
    // descriptor is open. Without the flags, the child holds the probe lock
    // after the `close(2)` of this call, and the next reader of the same
    // snapshot sees a lock that no lease holds.
    let descriptor = open(
      directory.path, O_RDONLY | O_DIRECTORY | MarketplaceCache.noInheritanceOpenFlags)
    if descriptor < 0 {
      return false
    }
    defer { close(descriptor) }
    return flock(descriptor, LOCK_EX | LOCK_NB) != 0
  }
}

/// Reads the descriptor flags of the open descriptors of this process that
/// name one path.
///
/// A lock test must prove that no child process can get a lock descriptor. A
/// test that starts child processes and looks for a stale lock depends on the
/// speed of the host: the descriptor is in the child only between the fork
/// step and the exec step of the spawn. The flags of the descriptor do not
/// depend on time, thus the tests read the flags.
enum OpenDescriptorProbe {
  /// The descriptor flags that keep a descriptor out of each child process:
  /// the kernel does not copy it at the fork step, and closes it at the exec
  /// step.
  static let noInheritanceFlags = FD_CLOEXEC | FD_CLOFORK

  /// The `fcntl(F_GETFD)` flags of each open descriptor that names `path`.
  ///
  /// - Parameter path: The file or folder. The call resolves its symbolic
  ///   links, because the kernel reports the resolved path of a descriptor.
  /// - Returns: One flag value for each descriptor, in descriptor order.
  ///   The result is empty when no descriptor names the path.
  static func descriptorFlags(ofOpensAt path: String) -> [Int32] {
    guard let resolved = realpath(path, nil) else {
      return []
    }
    defer { free(resolved) }
    let target = String(cString: resolved)
    return openDescriptors()
      .filter { self.path(ofDescriptor: $0) == target }
      .map { fcntl($0, F_GETFD) }
      .filter { $0 >= 0 }
  }

  /// The numbers of the open descriptors of this process.
  ///
  /// - Returns: The descriptor numbers. A descriptor that a different thread
  ///   closes during the call can be in the result; the callers ignore a
  ///   descriptor that gives an error.
  private static func openDescriptors() -> [Int32] {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let byteCount = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard byteCount > 0 else {
      return []
    }
    var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / stride)
    let written = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &entries, byteCount)
    return entries.prefix(max(0, Int(written)) / stride).map(\.proc_fd)
  }

  /// The path that the kernel reports for one descriptor.
  ///
  /// - Parameter descriptor: The descriptor number.
  /// - Returns: The path, or `nil` when the descriptor names no file.
  private static func path(ofDescriptor descriptor: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
      return nil
    }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }
}
