import FixtureSupport
import Foundation

/// A throwaway git repository built from one parity suite's fixtures, so that
/// `git check-ignore` has something real to answer about.
struct ScratchRepository {
  /// The repository's root directory.
  let root: URL

  /// Builds the repository for `suite` inside `scratchDirectory`: `git init`,
  /// the ignore files written from their fixtures, and every probe path created
  /// on disk.
  ///
  /// - Parameters:
  ///   - suite: The suite to build a repository for.
  ///   - scratchDirectory: The directory the repository is created inside.
  /// - Returns: The built repository.
  /// - Throws: `FixtureError` if a fixture cannot be read or `git init` fails,
  ///   and whatever `FileManager` raises on a write.
  static func materialize(
    suite: IgnoreParitySuite, scratchDirectory: URL
  ) throws -> ScratchRepository {
    let root = scratchDirectory.appendingPathComponent("repo-\(suite.name)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Subprocess.runExpectingSuccess(
      arguments: ["git", "init", "-q"], currentDirectory: root,
      scratchDirectory: scratchDirectory)

    let repository = ScratchRepository(root: root)
    try repository.writeIgnoreFile(
      from: suite.gitignoreFixturePath, to: IgnoreParitySuite.gitignorePath)
    if let excludeFixturePath = suite.excludeFixturePath {
      try repository.writeIgnoreFile(
        from: excludeFixturePath, to: IgnoreParitySuite.excludePath)
    }
    for probePath in suite.probePaths {
      try repository.create(probePath: probePath)
    }
    return repository
  }

  /// Copies one checked-in ignore fixture into the repository, at the path git
  /// reads that layer from.
  ///
  /// - Parameters:
  ///   - fixturePath: The fixture's path relative to the package root.
  ///   - repositoryPath: Where the bytes go inside the repository.
  /// - Throws: `FixtureError` if the fixture cannot be read, and whatever
  ///   `String.write(to:)` raises.
  private func writeIgnoreFile(from fixturePath: String, to repositoryPath: String) throws {
    try FixtureFile.text(fixturePath).get()
      .write(
        to: root.appendingPathComponent(repositoryPath), atomically: true, encoding: .utf8)
  }

  /// Creates one probe path under the repository: a directory for a
  /// trailing-slash path, an empty file otherwise.
  ///
  /// Intermediate parent directories are created either way.
  ///
  /// - Parameter probePath: The relative probe path to create.
  /// - Throws: `FixtureError` if an empty file cannot be created, and whatever
  ///   `FileManager` raises when a directory cannot be created.
  private func create(probePath: String) throws {
    let isDirectory = probePath.hasSuffix("/")
    let trimmed = isDirectory ? String(probePath.dropLast()) : probePath
    guard !trimmed.isEmpty else { return }

    let fullURL = root.appendingPathComponent(trimmed)
    guard !isDirectory else {
      try FileManager.default.createDirectory(at: fullURL, withIntermediateDirectories: true)
      return
    }

    let parent = fullURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: fullURL.path) else { return }
    guard FileManager.default.createFile(atPath: fullURL.path, contents: nil) else {
      throw FixtureError(message: "could not create the probe file at \(fullURL.path)")
    }
  }
}
