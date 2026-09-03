import Foundation
import Testing

@testable import FoundationModelsExtras

/// Git parity for `IgnoreProcessor`'s `+` combination operator: git layers a
/// repository's `.git/info/exclude` (lower precedence) under its
/// `.gitignore` (higher precedence), which maps exactly to
/// `IgnoreProcessor(excludeFile) + IgnoreProcessor(gitignoreFile)`.
///
/// **The expectations come from a real git run.**
/// `Fixtures/ignore-combination/git-verdicts.json` records what `git
/// check-ignore --verbose --non-matching` answered, in a repository whose
/// `.git/info/exclude` and `.gitignore` hold the two fixtures beside it,
/// together with the git version that answered.
/// `Scripts/record-git-parity-snapshots.swift` makes that file again; run it
/// after a git upgrade and read the diff, because a changed verdict is
/// either a change in git's own behaviour or a defect, and either way a
/// person decides.
///
/// The two ignore files are fixtures rather than inline strings so the
/// recorder and this suite read the same bytes and cannot drift. Nothing
/// here starts a process, so the suite runs every time — no conditional
/// trait, and no silent skip.
@Suite struct IgnoreProcessorCombinationGitParityTests {

  /// The source name git reports for the lower-precedence layer.
  static let excludeSource = ".git/info/exclude"
  /// The source name git reports for the higher-precedence layer.
  static let gitignoreSource = ".gitignore"

  /// Lower-precedence rules, which the recorder writes into
  /// `.git/info/exclude`.
  static let exclude = IgnoreParityFixture.loadProcessor(
    "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/exclude.txt",
    source: excludeSource)

  /// Higher-precedence rules, which the recorder writes into `.gitignore`.
  /// They override the exclude file's `*.log` for `important.log`.
  static let gitignore = IgnoreParityFixture.loadProcessor(
    "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/gitignore.txt",
    source: gitignoreSource)

  /// The paths to probe. The recorder holds its own copy as
  /// `combinationProbePaths`; `snapshotCoversEveryProbe` below is the guard
  /// against the two copies drifting.
  static let probePaths = [
    "important.log", "debug.log", "build/x.o", "readme.md",
  ]

  /// The recorded git answer for this layering, decoded once. A missing or
  /// undecodable snapshot is held here as a failure and thrown by every
  /// test that needs it.
  static let snapshot = IgnoreParityFixture.loadSnapshot(
    "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/git-verdicts.json")

  /// Projects a verdict down to the deciding rule's source and line, or
  /// `nil` if nothing decided it.
  ///
  /// - Parameter verdict: The verdict to read.
  /// - Returns: The deciding rule's source and 1-based line, or `nil` when
  ///   no rule matched.
  private static func deciding(_ verdict: IgnoreVerdict) -> (source: String, line: Int)? {
    switch verdict.reason {
    case .matched(let rule): return (rule.source, rule.line)
    case .parentExcluded(_, let rule): return (rule.source, rule.line)
    case .noRuleMatched: return nil
    }
  }

  @Test(arguments: probePaths)
  func combinedLayeringMatchesRecordedGitVerdict(_ probe: String) throws {
    let git = try #require(
      try Self.snapshot.get().verdict(for: probe),
      "the snapshot holds no verdict for probe \(probe)")
    let combined = try Self.exclude.get() + Self.gitignore.get()
    let ours = combined.evaluate(probe)

    #expect(ours.isIgnored == git.isIgnored, "probe \(probe): ours=\(ours) git=\(git)")

    let ourDeciding = Self.deciding(ours)
    #expect(ourDeciding?.line == git.line, "probe \(probe): ours=\(ours) git=\(git)")
    #expect(ourDeciding?.source == git.source, "probe \(probe): ours=\(ours) git=\(git)")
  }

  @Test func snapshotCoversEveryProbe() throws {
    try Self.snapshot.get().expectCoverage(of: Self.probePaths)
  }
}
