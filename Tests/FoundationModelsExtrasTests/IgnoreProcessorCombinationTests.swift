import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `IgnoreProcessor`'s `+`/`+=` combination operators:
/// override-on-combine, reversed-order winner flips, parent-directory
/// exclusion across combined sources, associativity, and `+=`
/// accumulation.
@Suite struct IgnoreProcessorCombinationTests {

  // MARK: - Override on combine

  @Test func rightOperandRuleWinsAndVerdictCitesItsSource() {
    let gitignore = IgnoreProcessor(string: "*.log\n", source: ".gitignore")
    let reviewignore = IgnoreProcessor(string: "!important.log\n", source: ".reviewignore")

    let combined = gitignore + reviewignore

    let important = combined.evaluate("important.log")
    let debug = combined.evaluate("debug.log")

    #expect(important.isIgnored == false)
    guard case .matched(let importantRule) = important.reason else {
      Issue.record("expected .matched reason for important.log, got \(important.reason)")
      return
    }
    #expect(importantRule.source == ".reviewignore")
    #expect(importantRule.line == 1)

    #expect(debug.isIgnored == true)
    guard case .matched(let debugRule) = debug.reason else {
      Issue.record("expected .matched reason for debug.log, got \(debug.reason)")
      return
    }
    #expect(debugRule.source == ".gitignore")
    #expect(debugRule.line == 1)
  }

  @Test func combinedRulesAreLhsRulesFollowedByRhsRules() {
    let lhs = IgnoreProcessor(string: "*.log\n", source: ".gitignore")
    let rhs = IgnoreProcessor(string: "!important.log\n", source: ".reviewignore")

    let combined = lhs + rhs

    #expect(combined.rules.count == 2)
    #expect(combined.rules[0].source == ".gitignore")
    #expect(combined.rules[1].source == ".reviewignore")
  }

  // MARK: - Reversed order flips the winner

  @Test func reversedCombinationOrderFlipsWhichRuleWins() {
    let gitignore = IgnoreProcessor(string: "*.log\n", source: ".gitignore")
    let reviewignore = IgnoreProcessor(string: "!important.log\n", source: ".reviewignore")

    let gitignoreWins = reviewignore + gitignore
    let reviewignoreWins = gitignore + reviewignore

    let viaGitignoreWins = gitignoreWins.evaluate("important.log")
    let viaReviewignoreWins = reviewignoreWins.evaluate("important.log")

    #expect(viaGitignoreWins.isIgnored == true)
    guard case .matched(let winningRule) = viaGitignoreWins.reason else {
      Issue.record("expected .matched reason, got \(viaGitignoreWins.reason)")
      return
    }
    #expect(winningRule.source == ".gitignore")

    #expect(viaReviewignoreWins.isIgnored == false)
    guard case .matched(let otherWinningRule) = viaReviewignoreWins.reason else {
      Issue.record("expected .matched reason, got \(viaReviewignoreWins.reason)")
      return
    }
    #expect(otherWinningRule.source == ".reviewignore")
  }

  // MARK: - Parent-directory exclusion across combined sources

  @Test func parentExclusionByLhsCannotBeReincludedByRhsNegationOnChild() {
    let lhs = IgnoreProcessor(string: "build/\n", source: ".gitignore")
    let rhs = IgnoreProcessor(string: "!build/out/a.o\n", source: ".reviewignore")

    let combined = lhs + rhs

    let verdict = combined.evaluate("build/out/a.o")

    #expect(verdict.isIgnored == true)
    guard case .parentExcluded(let ancestor, let rule) = verdict.reason else {
      Issue.record("expected .parentExcluded reason, got \(verdict.reason)")
      return
    }
    #expect(ancestor == "build")
    #expect(rule.source == ".gitignore")
  }

  @Test func rhsCanLiftAnLhsParentExclusionByReincludingTheAncestorItself() {
    let lhs = IgnoreProcessor(string: "build/\n", source: ".gitignore")
    let rhs = IgnoreProcessor(string: "!build/\n", source: ".reviewignore")

    let combined = lhs + rhs

    let verdict = combined.evaluate("build/out/a.o")

    #expect(verdict.isIgnored == false)
    #expect(verdict.reason == .noRuleMatched)
  }

  // MARK: - Associativity

  @Test func combinationIsAssociativeOverAProbeSet() {
    let a = IgnoreProcessor(string: "*.log\nbuild/\n", source: "a")
    let b = IgnoreProcessor(string: "!important.log\n!build/keep.txt\n", source: "b")
    let c = IgnoreProcessor(string: "*.tmp\nbuild/keep.txt\n", source: "c")

    let leftAssociative = (a + b) + c
    let rightAssociative = a + (b + c)

    let probes = [
      "important.log", "debug.log", "scratch.tmp", "build/keep.txt", "build/out/a.o",
      "readme.md",
    ]

    for probe in probes {
      let left = leftAssociative.evaluate(probe)
      let right = rightAssociative.evaluate(probe)
      #expect(left.isIgnored == right.isIgnored, "probe \(probe): left=\(left) right=\(right)")
      #expect(left.reason == right.reason, "probe \(probe): left=\(left) right=\(right)")
    }
  }

  // MARK: - `+=` accumulation

  @Test func plusEqualsAccumulatesRhsRulesOntoLhs() {
    var combined = IgnoreProcessor(string: "*.log\n", source: ".gitignore")
    combined += IgnoreProcessor(string: "!important.log\n", source: ".reviewignore")

    #expect(combined.rules.count == 2)

    let verdict = combined.evaluate("important.log")
    #expect(verdict.isIgnored == false)
    guard case .matched(let rule) = verdict.reason else {
      Issue.record("expected .matched reason, got \(verdict.reason)")
      return
    }
    #expect(rule.source == ".reviewignore")
  }

  @Test func plusEqualsIsEquivalentToPlus() {
    let lhs = IgnoreProcessor(string: "*.log\n", source: ".gitignore")
    let rhs = IgnoreProcessor(string: "!important.log\n", source: ".reviewignore")

    var accumulated = lhs
    accumulated += rhs
    let combined = lhs + rhs

    #expect(accumulated.rules == combined.rules)
  }
}
