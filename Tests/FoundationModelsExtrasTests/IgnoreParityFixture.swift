import FixtureSupport
import Foundation
import Testing

@testable import FoundationModelsExtras

/// Loads one ignore-parity suite for a test: the ignore files git reads, and
/// the recorded `git check-ignore` snapshot beside them.
///
/// Every loader returns a `Result` rather than throwing, so a suite can hold one
/// in a `static let`, load the fixture once, and still surface a missing or
/// undecodable file as a thrown test failure instead of a crash or, worse, a
/// test that quietly passes over it.
enum IgnoreParityFixture {

  /// Loads a suite's ignore layers and combines them the way git layers them:
  /// `.git/info/exclude` under `.gitignore`.
  ///
  /// Each layer's rules carry the source name git itself reports for that layer,
  /// so a verdict's provenance reads the same on both sides.
  ///
  /// - Parameter suite: The suite whose ignore layers to load.
  /// - Returns: The combined processor, or the failure that stopped it.
  static func loadProcessor(
    for suite: IgnoreParitySuite
  ) -> Result<IgnoreProcessor, FixtureError> {
    let gitignore = loadProcessor(
      suite.gitignoreFixturePath, source: IgnoreParitySuite.gitignorePath)
    guard let excludeFixturePath = suite.excludeFixturePath else { return gitignore }
    return loadProcessor(excludeFixturePath, source: IgnoreParitySuite.excludePath)
      .flatMap { exclude in gitignore.map { exclude + $0 } }
  }

  /// Loads the recorded git answer for a suite.
  ///
  /// - Parameter suite: The suite whose snapshot to read.
  /// - Returns: The decoded snapshot, or the failure that stopped it — a
  ///   missing file and a file that will not decode are both failures, so
  ///   neither can pass in silence.
  static func loadSnapshot(
    for suite: IgnoreParitySuite
  ) -> Result<GitVerdictSnapshot, FixtureError> {
    FixtureFile.gitVerdictSnapshot(suite.snapshotPath)
  }

  /// Loads one ignore file and parses it into a processor.
  ///
  /// - Parameters:
  ///   - relativePath: The ignore file's path relative to the package root.
  ///   - source: The display name recorded on every parsed rule, stated as the
  ///     name git itself reports for that layer.
  /// - Returns: The parsed processor, or the failure that stopped it.
  private static func loadProcessor(
    _ relativePath: String, source: String
  ) -> Result<IgnoreProcessor, FixtureError> {
    FixtureFile.text(relativePath).map { IgnoreProcessor(string: $0, source: source) }
  }
}

extension GitVerdictSnapshot {
  /// Checks that this snapshot answers for exactly the paths `probePaths`
  /// names, and that it carries the provenance that makes it reproducible.
  ///
  /// The probe list and the snapshot are recorded at different moments, so this
  /// is the guard against the snapshot going stale: a probe added to
  /// `IgnoreParitySuite` without a fresh recording fails the suite rather than
  /// passing in silence.
  ///
  /// - Parameters:
  ///   - probePaths: Every path the suite probes.
  ///   - sourceLocation: The calling test's location, so a failure is reported
  ///     there rather than here.
  func expectCoverage(
    of probePaths: [String], sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(Set(verdicts.map(\.path)) == Set(probePaths), sourceLocation: sourceLocation)
    #expect(verdicts.count == probePaths.count, sourceLocation: sourceLocation)
    #expect(recordedWith.hasPrefix("git version"), sourceLocation: sourceLocation)
    #expect(!recordedOn.isEmpty, sourceLocation: sourceLocation)
  }
}
