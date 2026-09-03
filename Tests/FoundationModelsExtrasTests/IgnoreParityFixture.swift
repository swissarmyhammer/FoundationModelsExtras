import Foundation
import Testing

@testable import FoundationModelsExtras

/// One path's outcome as `git check-ignore --verbose --non-matching`
/// reported it, decoded from a checked-in snapshot.
///
/// `source`, `line` and `pattern` are absent when git matched no rule at all
/// — its `::` output — so a verdict carrying none of the three is git saying
/// "nothing decided this path".
struct GitVerdict: Decodable, Sendable, CustomStringConvertible {
  /// The probed path, in the same trailing-slash-means-directory form
  /// `IgnoreProcessor.evaluate` and `git check-ignore` both use.
  let path: String
  /// Whether git considers the path ignored: it matched a pattern that does
  /// not begin with `!`.
  let isIgnored: Bool
  /// The file git attributes the deciding pattern to (`.gitignore`,
  /// `.git/info/exclude`), or `nil` when no rule matched.
  let source: String?
  /// The deciding pattern's 1-based line number in `source`, or `nil` when
  /// no rule matched.
  let line: Int?
  /// The deciding pattern's raw text, including any `!` negation prefix, or
  /// `nil` when no rule matched.
  let pattern: String?

  var description: String {
    guard let source, let line, let pattern else {
      return "\(path): no rule matched"
    }
    return "\(path): \(source):\(line):\(pattern)"
  }
}

/// One parity suite's whole recorded git answer, with the provenance that
/// makes it reproducible.
struct GitVerdictSnapshot: Decodable, Sendable {
  /// The `git --version` line of the run that recorded this file.
  let recordedWith: String
  /// The day the recording ran, as `yyyy-MM-dd`.
  let recordedOn: String
  /// Every probed path's verdict, sorted by `path`.
  let verdicts: [GitVerdict]

  /// The recorded verdict for one probed path.
  ///
  /// - Parameter path: The path to look up, spelled exactly as the probe
  ///   spells it.
  /// - Returns: The verdict, or `nil` when the snapshot holds none for
  ///   `path`.
  func verdict(for path: String) -> GitVerdict? {
    verdicts.first { $0.path == path }
  }

  /// Checks that this snapshot answers for exactly the paths `probePaths`
  /// names, and that it carries the provenance that makes it reproducible.
  ///
  /// The probe list lives in the test file and the recorder holds its own
  /// copy, so this is the guard against the two drifting: a path added on
  /// one side and not the other fails the suite rather than passing in
  /// silence.
  ///
  /// - Parameters:
  ///   - probePaths: Every path the suite probes.
  ///   - sourceLocation: The calling test's location, so a failure is
  ///     reported there rather than here.
  func expectCoverage(
    of probePaths: [String], sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(Set(verdicts.map(\.path)) == Set(probePaths), sourceLocation: sourceLocation)
    #expect(verdicts.count == probePaths.count, sourceLocation: sourceLocation)
    #expect(recordedWith.hasPrefix("git version"), sourceLocation: sourceLocation)
    #expect(!recordedOn.isEmpty, sourceLocation: sourceLocation)
  }
}

/// Reads the checked-in ignore-parity fixtures — the ignore files, and the
/// recorded `git check-ignore` snapshots beside them.
///
/// Every loader here returns a `Result` rather than throwing, so a suite can
/// hold one in a `static let`, load the fixture once, and still surface a
/// missing or undecodable file as a thrown test failure instead of a crash
/// or, worse, a test that quietly passes over it.
enum IgnoreParityFixture {

  /// A fixture that could not be read or decoded. Never an
  /// `IgnoreProcessor` failure — that type has its own error.
  struct LoadError: Error, Sendable, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  /// Resolves a fixture path stated relative to the package root.
  ///
  /// - Parameter relativePath: The fixture's path relative to the package
  ///   root.
  /// - Returns: The fixture's URL on disk.
  static func url(_ relativePath: String) -> URL {
    PackageRootValidation.packageRoot().appendingPathComponent(relativePath)
  }

  /// Loads an ignore file and parses it into a processor.
  ///
  /// - Parameters:
  ///   - relativePath: The ignore file's path relative to the package root.
  ///   - source: The display name recorded on every parsed rule. State the
  ///     name git itself reports for that layer (`.gitignore`,
  ///     `.git/info/exclude`), so a verdict's source can be compared against
  ///     the snapshot directly.
  /// - Returns: The parsed processor, or the failure that stopped it.
  static func loadProcessor(
    _ relativePath: String, source: String
  ) -> Result<IgnoreProcessor, LoadError> {
    loadText(relativePath).map { IgnoreProcessor(string: $0, source: source) }
  }

  /// Loads and decodes a recorded `git check-ignore` snapshot.
  ///
  /// - Parameter relativePath: The snapshot's path relative to the package
  ///   root.
  /// - Returns: The decoded snapshot, or the failure that stopped it — a
  ///   missing file and a file that will not decode are both failures, so
  ///   neither can pass in silence.
  static func loadSnapshot(_ relativePath: String) -> Result<GitVerdictSnapshot, LoadError> {
    loadText(relativePath).flatMap { text in
      do {
        return .success(
          try JSONDecoder().decode(GitVerdictSnapshot.self, from: Data(text.utf8)))
      } catch {
        return .failure(
          LoadError(
            message: """
              could not decode the git-verdict snapshot at \(url(relativePath).path): \
              \(error)
              """))
      }
    }
  }

  /// Reads one fixture as UTF-8 text.
  ///
  /// - Parameter relativePath: The fixture's path relative to the package
  ///   root.
  /// - Returns: The fixture's contents, or the failure that stopped it.
  private static func loadText(_ relativePath: String) -> Result<String, LoadError> {
    let fixtureURL = url(relativePath)
    guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
      return .failure(LoadError(message: "could not read the fixture at \(fixtureURL.path)"))
    }
    return .success(text)
  }
}
