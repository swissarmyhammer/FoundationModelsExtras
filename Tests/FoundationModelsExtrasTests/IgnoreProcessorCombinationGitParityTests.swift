import Foundation
import Testing

@testable import FoundationModelsExtras

/// Git-parity check for `IgnoreProcessor`'s `+` combination operator: git
/// layers a repository's `.git/info/exclude` (lower precedence) under its
/// `.gitignore` (higher precedence), which maps exactly to
/// `IgnoreProcessor(excludeFile) + IgnoreProcessor(gitignoreFile)`.
///
/// Reuses `GitParityHarness` (from `IgnoreGitParityTests.swift`) for repo
/// materialization and driving `git check-ignore --verbose`; only the
/// `.git/info/exclude` overwrite (git seeds that file with template
/// comments on `git init`, which `materializeRepo` doesn't know about) is
/// specific to this test. Skips cleanly when `git` isn't on `PATH`.
@Suite struct IgnoreProcessorCombinationGitParityTests {

  /// Lower-precedence rules, written into `.git/info/exclude`.
  static let excludeContents = "*.log\nbuild/\n"
  /// Higher-precedence rules, written into `.gitignore` — overrides the
  /// exclude file's `*.log` for `important.log`.
  static let gitignoreContents = "!important.log\n"

  static let probePaths = [
    "important.log", "debug.log", "build/x.o", "readme.md",
  ]

  /// Projects a verdict down to the deciding rule's source and line, or
  /// `nil` if nothing decided it.
  private static func deciding(_ verdict: IgnoreVerdict) -> (source: String, line: Int)? {
    switch verdict.reason {
    case .matched(let rule): return (rule.source, rule.line)
    case .parentExcluded(_, let rule): return (rule.source, rule.line)
    case .noRuleMatched: return nil
    }
  }

  @Test(.enabled(if: GitParityHarness.isGitAvailable()))
  func combinedExcludeAndGitignoreLayeringMatchesGitCheckIgnoreVerbose() throws {
    let repoURL = try GitParityHarness.materializeRepo(
      gitignoreContents: Self.gitignoreContents, probePaths: Self.probePaths)
    defer { try? FileManager.default.removeItem(at: repoURL) }

    // `git init` seeds `.git/info/exclude` with several lines of template
    // comments; overwrite it so its content — and therefore its line
    // numbers — matches exactly what `IgnoreProcessor(string:source:)`
    // below parses.
    let excludeURL = repoURL.appendingPathComponent(".git/info/exclude")
    try Self.excludeContents.write(to: excludeURL, atomically: true, encoding: .utf8)

    let gitVerdicts = try GitParityHarness.runCheckIgnore(
      probePaths: Self.probePaths, repoURL: repoURL)

    let exclude = IgnoreProcessor(string: Self.excludeContents, source: ".git/info/exclude")
    let gitignore = IgnoreProcessor(string: Self.gitignoreContents, source: ".gitignore")
    let combined = exclude + gitignore

    for probe in Self.probePaths {
      let ours = combined.evaluate(probe)
      guard let git = gitVerdicts[probe] else {
        Issue.record("git reported no result at all for probe \(probe)")
        continue
      }

      #expect(
        ours.isIgnored == git.isIgnored,
        "probe \(probe): ours=\(ours) git=\(git)")

      if let gitLine = git.line, let gitSource = git.source {
        let ourDeciding = Self.deciding(ours)
        #expect(
          ourDeciding?.line == gitLine,
          "probe \(probe): ours=\(ours) git=\(git)")
        #expect(
          ourDeciding?.source == gitSource,
          "probe \(probe): ours=\(ours) git=\(git)")
      }
    }
  }
}
