import FixtureSupport
import Foundation
import Testing

@testable import FoundationModelsExtras

/// Corpus-level git parity for `IgnoreProcessor`: a checked-in ~40-path probe
/// table exercises every pattern-surface bullet from the
/// `IgnoreRule`/`Wildmatch`/`IgnoreProcessor` tasks (comments, escapes, CRLF
/// lines, negation, anchoring, dir-only rules, `*`/`?`, bracket and POSIX
/// character classes, all three `**` forms, and parent-exclusion setups)
/// against the fixture at `Fixtures/ignore-corpus/gitignore.txt`.
///
/// **The expectations come from a real git run.** `Fixtures/ignore-corpus/
/// git-verdicts.json` records what `git check-ignore --verbose --non-matching`
/// answered for every probe `IgnoreParitySuite.corpus` names, together with the
/// git version that answered. `swift run record-git-parity-snapshots` makes
/// that file again; run it after a git upgrade and read the diff, because a
/// changed verdict is either a change in git's own behaviour or a defect, and
/// either way a person decides.
///
/// Nothing here starts a process. The suite runs every time, on every machine,
/// with or without `git` on `PATH` — the conditional trait that used to gate
/// the parity claim is gone, and with it the silent skip that proved nothing.
@Suite struct IgnoreGitParityTests {

  /// The suite under test: the corpus fixture, the probe corpus, and the
  /// snapshot recorded against them. The recorder reads the same rows, so
  /// neither side can hold a probe the other has not seen.
  ///
  /// No expected verdict is stated here. The snapshot is the only statement of
  /// what git answers; see `Fixtures/ignore-corpus/gitignore.txt` for the rules
  /// that decide each probe.
  static let suite = IgnoreParitySuite.corpus

  /// The corpus fixture, parsed once. Its rules carry the source name git
  /// itself reports, so a rule's provenance reads the same on both sides.
  static let processor = IgnoreParityFixture.loadProcessor(for: suite)

  /// The recorded git answer for this corpus, decoded once. A missing or
  /// undecodable snapshot is held here as a failure and thrown by every test
  /// that needs it.
  static let snapshot = IgnoreParityFixture.loadSnapshot(for: suite)

  /// Projects a verdict down to the deciding rule's line number, or `nil` if
  /// nothing decided it — the field the parity test compares against git's own.
  ///
  /// - Parameter verdict: The verdict to read.
  /// - Returns: The deciding rule's 1-based line, or `nil` when no rule
  ///   matched.
  private static func decidingLine(of verdict: IgnoreVerdict) -> Int? {
    switch verdict.reason {
    case .matched(let rule): return rule.line
    case .parentExcluded(_, let rule): return rule.line
    case .noRuleMatched: return nil
    }
  }

  // MARK: - Parity against the recorded git verdicts

  @Test(arguments: suite.probePaths)
  func verdictMatchesRecordedGitVerdict(_ probe: String) throws {
    let git = try #require(
      try Self.snapshot.get().verdict(for: probe),
      "the snapshot holds no verdict for probe \(probe)")
    let ours = try Self.processor.get().evaluate(probe)

    #expect(ours.isIgnored == git.isIgnored, "probe \(probe): ours=\(ours) git=\(git)")
    #expect(
      Self.decidingLine(of: ours) == git.line, "probe \(probe): ours=\(ours) git=\(git)")
  }

  @Test func snapshotCoversEveryProbe() throws {
    try Self.snapshot.get().expectCoverage(of: Self.suite.probePaths)
  }
}
