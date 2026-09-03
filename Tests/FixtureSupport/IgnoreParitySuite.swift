import Foundation

/// One ignore-parity suite: the ignore fixtures a repository is built from, the
/// paths probed against them, and the snapshot that records what git answered.
///
/// This table is the single statement of that shape. The
/// `record-git-parity-snapshots` tool builds a real repository from it, and the
/// test suites read the same rows, so a probe added on one side cannot go
/// missing on the other.
///
/// Every fixture path is stated relative to the package root.
public struct IgnoreParitySuite: Sendable {
  /// The path inside a repository that git reports for the higher-precedence
  /// ignore layer.
  public static let gitignorePath = ".gitignore"

  /// The path inside a repository that git reports for the lower-precedence
  /// ignore layer.
  ///
  /// `git init` seeds that file with template comments, so the recorder
  /// overwrites it rather than appending to it — the line numbers git reports
  /// have to be the line numbers of the fixture.
  public static let excludePath = ".git/info/exclude"

  /// The suite's name, used in the recorder's progress output and in the
  /// failure it raises for a probe git answered nothing about.
  public let name: String

  /// The fixture whose bytes become the repository's `.gitignore`.
  public let gitignoreFixturePath: String

  /// The fixture whose bytes overwrite the repository's `.git/info/exclude`,
  /// or `nil` for a suite with no exclude layer.
  public let excludeFixturePath: String?

  /// The paths to probe, following the same trailing-slash-means-directory
  /// convention `IgnoreProcessor.evaluate` and `git check-ignore` both use.
  ///
  /// Every path is materializable on disk without conflict — no path is asked
  /// to be both a file and a directory — which the recorder depends on when it
  /// builds a repository from this list.
  public let probePaths: [String]

  /// Where the recorded snapshot lives.
  public let snapshotPath: String

  /// Creates one suite.
  ///
  /// - Parameters:
  ///   - name: The suite's name.
  ///   - gitignoreFixturePath: The fixture that becomes `.gitignore`.
  ///   - excludeFixturePath: The fixture that becomes `.git/info/exclude`, or
  ///     `nil` for a suite with no exclude layer.
  ///   - probePaths: The paths to probe.
  ///   - snapshotPath: Where the recorded snapshot lives.
  public init(
    name: String, gitignoreFixturePath: String, excludeFixturePath: String?,
    probePaths: [String], snapshotPath: String
  ) {
    self.name = name
    self.gitignoreFixturePath = gitignoreFixturePath
    self.excludeFixturePath = excludeFixturePath
    self.probePaths = probePaths
    self.snapshotPath = snapshotPath
  }

  /// The corpus suite: one `.gitignore` exercising every pattern surface of
  /// `IgnoreRule`, `Wildmatch` and `IgnoreProcessor`.
  public static let corpus = IgnoreParitySuite(
    name: "ignore-corpus",
    gitignoreFixturePath:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/gitignore.txt",
    excludeFixturePath: nil,
    probePaths: [
      // Comments, escapes, and trailing-space handling.
      "#hashfile.txt",
      "!bangfile.txt",
      "escapedspace ",
      "escapedspace",

      // Basic wildcard with a negated re-include.
      "keep.log",
      "other.log",
      "deep/nested/other.log",
      "nested/keep.log",

      // Anchoring.
      "anchored.txt",
      "sub/anchored.txt",

      // Directory-only rule + parent-directory exclusion.
      "build/output.bin",
      "build/",
      "sub/build/x.bin",
      "sub/build/",

      // Single-character wildcard.
      "fileA.txt",
      "fileAB.txt",

      // Bracket character classes: `[!...]` and `[^...]` negation spellings.
      "xbracket.txt",
      "abracket.txt",
      "acaret.txt",
      "xcaret.txt",

      // Named POSIX character class.
      "digit5.txt",
      "digitA.txt",
      "digit10.txt",

      // Leading `**` — matches the same basename at any depth.
      "deep.tmp",
      "a/b/deep.tmp",

      // Interior `**` — zero or more path segments.
      "mid/inner.txt",
      "mid/x/inner.txt",
      "mid/x/y/inner.txt",

      // Trailing `**` — everything inside, one or more segments.
      "logs/a.txt",

      // Parent exclusion: a later rule cannot re-include a named descendant of
      // an excluded directory.
      "blocked/reachable.txt",
      "blocked/other.txt",
      "blocked/",

      // Parent exclusion lifted: re-including the ancestor itself lets a later
      // rule reach its descendants again.
      "lifted/thing.scratch",
      "lifted/other.txt",

      // Plain default-include paths and bare directory probes with no rule of
      // their own.
      "src/main.swift",
      "README.md",
      "notbuild.txt",
      "a/",
      "sub/",
      "deep/nested/",
    ],
    snapshotPath:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/git-verdicts.json")

  /// The combination suite: a `.git/info/exclude` layered under a `.gitignore`,
  /// which is the layering `IgnoreProcessor`'s `+` operator claims to match.
  public static let combination = IgnoreParitySuite(
    name: "ignore-combination",
    gitignoreFixturePath:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/gitignore.txt",
    excludeFixturePath:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/exclude.txt",
    probePaths: [
      "important.log", "debug.log", "build/x.o", "readme.md",
    ],
    snapshotPath:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/git-verdicts.json")

  /// Every suite, in the order the recorder records them.
  public static let all: [IgnoreParitySuite] = [corpus, combination]
}
