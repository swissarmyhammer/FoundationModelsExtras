import Foundation

/// A checked-in fixture that could not be read, decoded, or recorded.
///
/// One error type serves the whole fixture pipeline: the test target reports a
/// fixture it cannot load, and the `record-git-parity-snapshots` tool reports a
/// fixture it cannot produce. Never an `IgnoreProcessor` failure — that type
/// has its own error.
public struct FixtureError: Error, Sendable, CustomStringConvertible {
  /// What stopped the fixture, phrased to read as a test failure message.
  public let message: String

  /// Creates an error carrying `message`.
  ///
  /// - Parameter message: What stopped the fixture.
  public init(message: String) {
    self.message = message
  }

  /// The message, so an error interpolated into a failure reads as prose.
  public var description: String { message }
}

/// Reads the fixtures checked into the repository, which tests and tools both
/// resolve against the package root rather than through `Bundle.module`.
public enum FixtureFile {
  /// The package root, three levels up from this file's own path
  /// (`Tests/FixtureSupport/<file>.swift`).
  ///
  /// Deriving it from `#filePath` rather than the working directory lets the
  /// test bundle and the recorder tool find the same bytes whichever directory
  /// either is started from.
  public static let packageRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // <file>.swift -> FixtureSupport/
    .deletingLastPathComponent()  // FixtureSupport/ -> Tests/
    .deletingLastPathComponent()  // Tests/ -> package root

  /// Resolves a fixture path stated relative to the package root.
  ///
  /// - Parameter relativePath: The fixture's path relative to the package root.
  /// - Returns: The fixture's URL on disk.
  public static func url(_ relativePath: String) -> URL {
    packageRoot.appendingPathComponent(relativePath)
  }

  /// Reads one checked-in fixture as UTF-8 text.
  ///
  /// The answer is a `Result` rather than a `throws`, so a test suite can hold
  /// one in a `static let`, read the fixture once, and still surface a missing
  /// file as a thrown test failure instead of a crash. A tool that wants the
  /// throwing shape calls `get()` on it.
  ///
  /// - Parameter relativePath: The fixture's path relative to the package root.
  /// - Returns: The fixture's contents, or the failure that stopped it.
  public static func text(_ relativePath: String) -> Result<String, FixtureError> {
    let fixtureURL = url(relativePath)
    guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
      return .failure(FixtureError(message: "could not read the fixture at \(fixtureURL.path)"))
    }
    return .success(text)
  }
}
