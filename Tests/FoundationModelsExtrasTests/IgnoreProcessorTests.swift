import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `IgnoreProcessor`: construction from a string and
/// from a file, and `evaluate`'s last-match-wins, anchoring, directory-only,
/// and parent-exclusion semantics.
@Suite struct IgnoreProcessorTests {

  // MARK: - Construction

  @Test func stringInitParsesRulesAndRecordsSource() {
    let processor = IgnoreProcessor(string: "*.log\n!keep.log\n", source: ".gitignore")

    #expect(processor.rules.count == 2)
    #expect(processor.rules[0].pattern == "*.log")
    #expect(processor.rules[0].source == ".gitignore")
    #expect(processor.rules[0].line == 1)
    #expect(processor.rules[1].pattern == "keep.log")
    #expect(processor.rules[1].line == 2)
  }

  @Test func stringInitSkipsCommentsAndBlankLines() {
    let processor = IgnoreProcessor(
      string: "# comment\n\n*.log\n",
      source: ".gitignore")

    #expect(processor.rules.count == 1)
    #expect(processor.rules[0].pattern == "*.log")
    #expect(processor.rules[0].line == 3)
  }

  @Test func fileInitLoadsRulesFromDisk() throws {
    let directory = canonicalize(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent(".gitignore")
    try "*.log\n!keep.log\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let processor = try IgnoreProcessor(contentsOf: fileURL)

    #expect(processor.rules.count == 2)
    #expect(processor.rules[0].source == ".gitignore")
  }

  @Test func fileInitUsesFileNameAsSourceForAnyFileName() throws {
    let directory = canonicalize(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent(".reviewignore")
    try "*.log\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let processor = try IgnoreProcessor(contentsOf: fileURL)

    #expect(processor.rules[0].source == ".reviewignore")
  }

  @Test func fileInitThrowsForMissingFile() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("nope.gitignore")

    #expect(throws: IgnoreProcessorError.self) {
      _ = try IgnoreProcessor(contentsOf: missing)
    }
  }

  @Test func missingFileErrorDescriptionNamesThePath() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("does-not-exist.gitignore")

    do {
      _ = try IgnoreProcessor(contentsOf: missing)
      Issue.record("expected an error to be thrown")
    } catch let error as IgnoreProcessorError {
      #expect(error.description.contains(missing.path))
    } catch {
      Issue.record("unexpected error type: \(error)")
    }
  }

  // MARK: - No rule matched

  @Test func noRuleMatchedIsIncludedWithNoRuleMatchedReason() {
    let processor = IgnoreProcessor(string: "*.log\n", source: ".gitignore")

    let verdict = processor.evaluate("readme.md")

    #expect(verdict.isIgnored == false)
    #expect(verdict.reason == .noRuleMatched)
    #expect(verdict.description == "included (no rule matched)")
  }

  // MARK: - Last-match-wins

  @Test func lastMatchWinsNegationReincludesASpecificFile() {
    let processor = IgnoreProcessor(string: "*.log\n!keep.log\n", source: ".gitignore")

    let kept = processor.evaluate("keep.log")
    let other = processor.evaluate("other.log")

    #expect(kept.isIgnored == false)
    #expect(other.isIgnored == true)

    guard case .matched(let keptRule) = kept.reason else {
      Issue.record("expected .matched reason for keep.log")
      return
    }
    #expect(keptRule.pattern == "keep.log")
    #expect(keptRule.isNegated == true)
    #expect(keptRule.line == 2)

    guard case .matched(let otherRule) = other.reason else {
      Issue.record("expected .matched reason for other.log")
      return
    }
    #expect(otherRule.pattern == "*.log")
    #expect(otherRule.line == 1)
  }

  @Test func verdictDescriptionCitesSourceAndLine() {
    let processor = IgnoreProcessor(string: "*.log\n!important.log\n", source: ".reviewignore")

    let ignored = processor.evaluate("other.log")
    let included = processor.evaluate("important.log")

    #expect(ignored.description == "ignored by \".reviewignore\":1 `*.log`")
    #expect(included.description == "included by \".reviewignore\":2 `!important.log`")
  }

  @Test func laterRuleOverridesEarlierRuleOfTheSamePattern() {
    let processor = IgnoreProcessor(string: "*.log\n*.log\n", source: ".gitignore")

    let verdict = processor.evaluate("a.log")

    guard case .matched(let rule) = verdict.reason else {
      Issue.record("expected .matched reason")
      return
    }
    #expect(rule.line == 2)
  }

  // MARK: - Parent-directory exclusion

  @Test func directoryRuleIgnoresNestedFileViaParentExclusion() {
    let processor = IgnoreProcessor(string: "build/\n", source: ".gitignore")

    let verdict = processor.evaluate("build/out/a.o")

    #expect(verdict.isIgnored == true)
    guard case .parentExcluded(let ancestor, let rule) = verdict.reason else {
      Issue.record("expected .parentExcluded reason, got \(verdict.reason)")
      return
    }
    #expect(ancestor == "build")
    #expect(rule.pattern == "build")
    #expect(rule.line == 1)
  }

  @Test func negatingADescendantOfAnExcludedParentDoesNotReinclude() {
    let processor = IgnoreProcessor(
      string: "build/\n!build/out/a.o\n", source: ".gitignore")

    let verdict = processor.evaluate("build/out/a.o")

    #expect(verdict.isIgnored == true)
    guard case .parentExcluded(let ancestor, let rule) = verdict.reason else {
      Issue.record("expected .parentExcluded reason, got \(verdict.reason)")
      return
    }
    #expect(ancestor == "build")
    #expect(rule.pattern == "build")
  }

  @Test func negatingTheExcludedAncestorItselfLiftsTheExclusion() {
    let processor = IgnoreProcessor(
      string: "build/\n!build/\n", source: ".gitignore")

    let verdict = processor.evaluate("build/out/a.o")

    // The ancestor "build" is re-included by the later `!build/` rule, so no
    // ancestor is excluded any more and the file falls through to
    // "no rule matched" (nothing else names build/out/a.o directly).
    #expect(verdict.isIgnored == false)
    #expect(verdict.reason == .noRuleMatched)
  }

  @Test func negatingTheExcludedAncestorItselfAllowsASubsequentRuleToApplyToDescendants() {
    let processor = IgnoreProcessor(
      string: "build/\n!build/\n*.o\n", source: ".gitignore")

    let verdict = processor.evaluate("build/out/a.o")

    #expect(verdict.isIgnored == true)
    guard case .matched(let rule) = verdict.reason else {
      Issue.record("expected .matched reason, got \(verdict.reason)")
      return
    }
    #expect(rule.pattern == "*.o")
  }

  @Test func topLevelPathHasNoAncestorsToExclude() {
    let processor = IgnoreProcessor(string: "build/\n", source: ".gitignore")

    let verdict = processor.evaluate("build", isDirectory: true)

    guard case .matched(let rule) = verdict.reason else {
      Issue.record("expected .matched reason, got \(verdict.reason)")
      return
    }
    #expect(rule.pattern == "build")
    #expect(verdict.isIgnored == true)
  }

  // MARK: - Trailing-slash directory-probe convention

  @Test func trailingSlashOnPathIsEquivalentToIsDirectoryTrue() {
    let processor = IgnoreProcessor(string: "build/\n", source: ".gitignore")

    let viaSlash = processor.evaluate("build/")
    let viaFlag = processor.evaluate("build", isDirectory: true)

    #expect(viaSlash.isIgnored == viaFlag.isIgnored)
    #expect(viaSlash.reason == viaFlag.reason)
  }

  @Test func directoryOnlyRuleDoesNotMatchAFileProbeOfTheSameName() {
    let processor = IgnoreProcessor(string: "build/\n", source: ".gitignore")

    let verdict = processor.evaluate("build")

    #expect(verdict.isIgnored == false)
    #expect(verdict.reason == .noRuleMatched)
  }

  @Test func directoryOnlyRuleMatchesTheDirectoryProbe() {
    let processor = IgnoreProcessor(string: "build/\n", source: ".gitignore")

    let verdict = processor.evaluate("build/")

    #expect(verdict.isIgnored == true)
  }

  // MARK: - Anchoring / unanchored basename matching

  @Test func unanchoredGlobMatchesAtAnyDepth() {
    let processor = IgnoreProcessor(string: "*.log\n", source: ".gitignore")

    let verdict = processor.evaluate("deep/nested/x.log")

    #expect(verdict.isIgnored == true)
    guard case .matched(let rule) = verdict.reason else {
      Issue.record("expected .matched reason")
      return
    }
    #expect(rule.pattern == "*.log")
  }

  @Test func unanchoredLiteralDoesNotMatchAsASuffixOfAnotherComponent() {
    let processor = IgnoreProcessor(string: "foo\n", source: ".gitignore")

    let verdict = processor.evaluate("deep/xfoo")

    #expect(verdict.isIgnored == false)
    #expect(verdict.reason == .noRuleMatched)
  }

  @Test func unanchoredLiteralMatchesItsOwnComponentAtAnyDepth() {
    let processor = IgnoreProcessor(string: "foo\n", source: ".gitignore")

    let verdict = processor.evaluate("deep/nested/foo")

    #expect(verdict.isIgnored == true)
  }

  @Test func anchoredPatternMatchesOnlyTheRootPath() {
    let processor = IgnoreProcessor(string: "/todo.txt\n", source: ".gitignore")

    let root = processor.evaluate("todo.txt")
    let nested = processor.evaluate("deep/todo.txt")

    #expect(root.isIgnored == true)
    #expect(nested.isIgnored == false)
    #expect(nested.reason == .noRuleMatched)
  }

  // MARK: - Batch evaluate

  @Test func batchEvaluateReturnsVerdictsInInputOrder() {
    let processor = IgnoreProcessor(string: "*.log\n!keep.log\nbuild/\n", source: ".gitignore")

    let verdicts = processor.evaluate(["keep.log", "other.log", "build/", "readme.md"])

    #expect(verdicts.count == 4)
    #expect(verdicts[0].isIgnored == false)
    #expect(verdicts[1].isIgnored == true)
    #expect(verdicts[2].isIgnored == true)
    #expect(verdicts[3].isIgnored == false)
    #expect(verdicts[3].reason == .noRuleMatched)
  }

  // MARK: - Leading "./" normalization

  @Test func leadingDotSlashIsNormalizedAway() {
    let processor = IgnoreProcessor(string: "*.log\n", source: ".gitignore")

    let plain = processor.evaluate("a.log")
    let dotSlash = processor.evaluate("./a.log")

    #expect(plain.isIgnored == dotSlash.isIgnored)
    #expect(dotSlash.isIgnored == true)
  }
}
