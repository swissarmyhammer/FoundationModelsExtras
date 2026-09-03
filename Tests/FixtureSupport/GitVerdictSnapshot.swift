import Foundation

/// One path's outcome as `git check-ignore --verbose --non-matching` reported
/// it.
///
/// `source`, `line` and `pattern` are absent when git matched no rule at all —
/// its `::` output — so a verdict that carries none of the three is git saying
/// "nothing decided this path".
public struct GitVerdict: Codable, Sendable, CustomStringConvertible {
  /// The probed path, in the same trailing-slash-means-directory form
  /// `IgnoreProcessor.evaluate` and `git check-ignore` both use.
  public let path: String
  /// Whether git considers the path ignored: it matched a pattern that does not
  /// begin with `!`.
  public let isIgnored: Bool
  /// The file git attributes the deciding pattern to (`.gitignore`,
  /// `.git/info/exclude`), or `nil` when no rule matched.
  public let source: String?
  /// The deciding pattern's 1-based line number in `source`, or `nil` when no
  /// rule matched.
  public let line: Int?
  /// The deciding pattern's raw text, including any `!` negation prefix, or
  /// `nil` when no rule matched.
  public let pattern: String?

  /// Creates one recorded verdict.
  ///
  /// - Parameters:
  ///   - path: The probed path.
  ///   - isIgnored: Whether git considers the path ignored.
  ///   - source: The file the deciding pattern comes from, or `nil` when no
  ///     rule matched.
  ///   - line: The deciding pattern's 1-based line number, or `nil` when no
  ///     rule matched.
  ///   - pattern: The deciding pattern's raw text, or `nil` when no rule
  ///     matched.
  public init(path: String, isIgnored: Bool, source: String?, line: Int?, pattern: String?) {
    self.path = path
    self.isIgnored = isIgnored
    self.source = source
    self.line = line
    self.pattern = pattern
  }

  /// The verdict on one line, in git's own `source:line:pattern` spelling, so a
  /// failure message states what git said.
  public var description: String {
    guard let source, let line, let pattern else {
      return "\(path): no rule matched"
    }
    return "\(path): \(source):\(line):\(pattern)"
  }
}

/// One parity suite's whole recorded git answer, with the provenance that makes
/// it reproducible.
public struct GitVerdictSnapshot: Codable, Sendable {
  /// The `git --version` line of the run that recorded this file.
  public let recordedWith: String
  /// The day the recording ran, as `yyyy-MM-dd`.
  public let recordedOn: String
  /// Every probed path's verdict, sorted by `path` so a later recording gives a
  /// diff a person can read.
  public let verdicts: [GitVerdict]

  /// Creates one snapshot.
  ///
  /// - Parameters:
  ///   - recordedWith: The `git --version` line of the recording run.
  ///   - recordedOn: The day the recording ran, as `yyyy-MM-dd`.
  ///   - verdicts: Every probed path's verdict, sorted by `path`.
  public init(recordedWith: String, recordedOn: String, verdicts: [GitVerdict]) {
    self.recordedWith = recordedWith
    self.recordedOn = recordedOn
    self.verdicts = verdicts
  }

  /// The recorded verdict for one probed path.
  ///
  /// - Parameter path: The path to look up, spelled exactly as the probe spells
  ///   it.
  /// - Returns: The verdict, or `nil` when the snapshot holds none for `path`.
  public func verdict(for path: String) -> GitVerdict? {
    verdicts.first { $0.path == path }
  }
}

extension FixtureFile {
  /// Reads and decodes one recorded `git check-ignore` snapshot.
  ///
  /// - Parameter relativePath: The snapshot's path relative to the package
  ///   root.
  /// - Returns: The decoded snapshot, or the failure that stopped it — a
  ///   missing file and a file that will not decode are both failures, so
  ///   neither can pass in silence.
  public static func gitVerdictSnapshot(
    _ relativePath: String
  ) -> Result<GitVerdictSnapshot, FixtureError> {
    text(relativePath).flatMap { json in
      do {
        return .success(try JSONDecoder().decode(GitVerdictSnapshot.self, from: Data(json.utf8)))
      } catch {
        return .failure(
          FixtureError(
            message: """
              could not decode the git-verdict snapshot at \(url(relativePath).path): \
              \(error)
              """))
      }
    }
  }
}
