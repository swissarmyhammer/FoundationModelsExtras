import Foundation
import Testing

@testable import FoundationModelsExtras

/// Corpus-level git parity for `IgnoreProcessor`: a checked-in ~40-path
/// probe table exercises every pattern-surface bullet from the
/// `IgnoreRule`/`Wildmatch`/`IgnoreProcessor` tasks (comments, escapes,
/// CRLF lines, negation, anchoring, dir-only rules, `*`/`?`, bracket and
/// POSIX character classes, all three `**` forms, and parent-exclusion
/// setups) against the fixture at
/// `Fixtures/ignore-corpus/gitignore.txt`.
///
/// **The expectations come from a real git run.** `Fixtures/ignore-corpus/
/// git-verdicts.json` records what `git check-ignore --verbose
/// --non-matching` answered for every probe below, together with the git
/// version that answered. `Scripts/record-git-parity-snapshots.swift` makes
/// that file again; run it after a git upgrade and read the diff, because a
/// changed verdict is either a change in git's own behaviour or a defect,
/// and either way a person decides.
///
/// Nothing here starts a process. The suite runs every time, on every
/// machine, with or without `git` on `PATH` — the conditional trait that
/// used to gate the parity claim is gone, and with it the silent skip that
/// proved nothing.
@Suite struct IgnoreGitParityTests {

  // MARK: - Probe corpus

  /// The probe corpus: one relative path per line, following the same
  /// trailing-slash-means-directory convention `IgnoreProcessor.evaluate`
  /// and `git check-ignore` both use.
  ///
  /// Every path is materializable on disk without conflict (no path is
  /// asked to be both a file and a directory), which the recorder depends
  /// on when it builds a real git repository from this same list — it holds
  /// its own copy as `corpusProbePaths`. `snapshotCoversEveryProbe` below
  /// is the guard against the two copies drifting.
  ///
  /// No expected verdict is stated here. The snapshot is the only statement
  /// of what git answers; see `Fixtures/ignore-corpus/gitignore.txt` for
  /// the rules that decide each of these.
  static let probes: [String] = [
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

    // Parent exclusion: a later rule cannot re-include a named descendant
    // of an excluded directory.
    "blocked/reachable.txt",
    "blocked/other.txt",
    "blocked/",

    // Parent exclusion lifted: re-including the ancestor itself lets a
    // later rule reach its descendants again.
    "lifted/thing.scratch",
    "lifted/other.txt",

    // Plain default-include paths and bare directory probes with no rule
    // of their own.
    "src/main.swift",
    "README.md",
    "notbuild.txt",
    "a/",
    "sub/",
    "deep/nested/",
  ]

  /// The corpus fixture, parsed once. Its rules carry the source name git
  /// itself reports, so a rule's provenance reads the same on both sides.
  static let processor = IgnoreParityFixture.loadProcessor(
    "Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/gitignore.txt",
    source: ".gitignore")

  /// The recorded git answer for this corpus, decoded once. A missing or
  /// undecodable snapshot is held here as a failure and thrown by every
  /// test that needs it.
  static let snapshot = IgnoreParityFixture.loadSnapshot(
    "Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/git-verdicts.json")

  /// Projects a verdict down to the deciding rule's line number, or `nil`
  /// if nothing decided it — the field the parity test compares against
  /// git's own.
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

  @Test(arguments: probes)
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
    try Self.snapshot.get().expectCoverage(of: Self.probes)
  }
}
