import Foundation

/// Makes a new, empty temporary directory for a test fixture.
///
/// Each call makes `<temporary directory>/<UUID>` and resolves it with
/// `URL.canonicalDirectory`, thus every URL built from it compares equal to
/// what directory enumeration and a tool run inside it report. The caller
/// removes the directory when the fixture is released.
///
/// Shared by the `MarketplaceFixtures` git fixture and by the test suites
/// that build a throwaway tree, so one place makes the folder the same way.
public enum TemporaryDirectory {
  /// Makes a new empty directory.
  ///
  /// - Returns: The canonical URL of the directory.
  /// - Throws: The error of `FileManager.createDirectory`.
  public static func make() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.canonicalDirectory
  }
}
