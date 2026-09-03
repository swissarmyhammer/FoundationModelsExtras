import FixtureSupport
import Foundation
import Testing

@testable import FoundationModelsExtras

/// Git parity for `IgnoreProcessor`'s `+` combination operator: git layers a
/// repository's `.git/info/exclude` (lower precedence) under its `.gitignore`
/// (higher precedence), which maps exactly to
/// `IgnoreProcessor(excludeFile) + IgnoreProcessor(gitignoreFile)`.
///
/// **The expectations come from a real git run.**
/// `Fixtures/ignore-combination/git-verdicts.json` records what `git
/// check-ignore --verbose --non-matching` answered, in a repository whose
/// `.git/info/exclude` and `.gitignore` hold the two fixtures beside it,
/// together with the git version that answered. `swift run
/// record-git-parity-snapshots` makes that file again; run it after a git
/// upgrade and read the diff, because a changed verdict is either a change in
/// git's own behaviour or a defect, and either way a person decides.
///
/// The two ignore files are fixtures rather than inline strings, and
/// `IgnoreParitySuite.combination` names them for the recorder and for this
/// suite alike, so the two read the same bytes and cannot drift. Nothing here
/// starts a process, so the suite runs every time — no conditional trait, and
/// no silent skip.
@Suite struct IgnoreProcessorCombinationGitParityTests {

  /// The suite under test: the two ignore fixtures, the paths probed against
  /// them, and the snapshot recorded from a real git run.
  static let suite = IgnoreParitySuite.combination

  /// The two layers, parsed once and combined the way git layers them. Each
  /// layer's rules carry the source name git itself reports, so a verdict's
  /// source can be compared against the snapshot directly.
  static let processor = IgnoreParityFixture.loadProcessor(for: suite)

  /// The recorded git answer for this layering, decoded once. A missing or
  /// undecodable snapshot is held here as a failure and thrown by every test
  /// that needs it.
  static let snapshot = IgnoreParityFixture.loadSnapshot(for: suite)

  /// Projects a verdict down to the deciding rule's source and line, or `nil`
  /// if nothing decided it.
  ///
  /// - Parameter verdict: The verdict to read.
  /// - Returns: The deciding rule's source and 1-based line, or `nil` when no
  ///   rule matched.
  private static func deciding(_ verdict: IgnoreVerdict) -> (source: String, line: Int)? {
    switch verdict.reason {
    case .matched(let rule): return (rule.source, rule.line)
    case .parentExcluded(_, let rule): return (rule.source, rule.line)
    case .noRuleMatched: return nil
    }
  }

  @Test(arguments: suite.probePaths)
  func combinedLayeringMatchesRecordedGitVerdict(_ probe: String) throws {
    let git = try #require(
      try Self.snapshot.get().verdict(for: probe),
      "the snapshot holds no verdict for probe \(probe)")
    let ours = try Self.processor.get().evaluate(probe)

    #expect(ours.isIgnored == git.isIgnored, "probe \(probe): ours=\(ours) git=\(git)")

    let ourDeciding = Self.deciding(ours)
    #expect(ourDeciding?.line == git.line, "probe \(probe): ours=\(ours) git=\(git)")
    #expect(ourDeciding?.source == git.source, "probe \(probe): ours=\(ours) git=\(git)")
  }

  @Test func snapshotCoversEveryProbe() throws {
    try Self.snapshot.get().expectCoverage(of: Self.suite.probePaths)
  }
}
