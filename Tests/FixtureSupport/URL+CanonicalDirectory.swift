import Foundation

#if canImport(Darwin)
  import Darwin
#endif

extension URL {
  /// This URL resolved to its real, symlink- and firmlink-free path via POSIX
  /// `realpath(3)`, marked as a directory.
  ///
  /// On macOS, `/var` (and so `FileManager.default.temporaryDirectory`) is a
  /// *firmlink* to `/private/var` — a construct `resolvingSymlinksInPath()`
  /// deliberately does not cross, while `FileManager.contentsOfDirectory`
  /// returns paths that already have crossed it through the kernel's own path
  /// resolution. A throwaway fixture root is resolved once at creation, so
  /// every URL built from it compares equal to what directory enumeration
  /// returns, and to what a tool run inside it reports.
  ///
  /// The URL comes back unchanged when `realpath(3)` fails, which is the case
  /// for a path that does not exist yet.
  ///
  /// Shared by the `FoundationModelsExtrasTests` suites that build throwaway
  /// fixture trees under a temporary directory, and by the
  /// `record-git-parity-snapshots` tool, which builds a git repository the same
  /// way. `AgentsMd` resolves paths the same way for its own walk, but that
  /// resolution is `private` to the library under test, and a fixture built
  /// with the code under test proves less than one built independently of it.
  public var canonicalDirectory: URL {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { return self }
    let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
    let resolvedPath = String(
      decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
    return URL(fileURLWithPath: resolvedPath, isDirectory: true)
  }
}
