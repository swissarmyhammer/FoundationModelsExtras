import FixtureSupport
import Foundation

/// The `git check-ignore` run, and the parser for what it writes.
///
/// This is the ONLY place the project starts a `git` process for ignore parity.
/// `swift test` reads the recorded snapshots and starts nothing.
enum GitCheckIgnore {
  /// The exit status `git check-ignore` uses for a fatal error, as distinct
  /// from `0` (something matched) and `1` (nothing matched) — both of which are
  /// normal runs.
  static let fatalStatus: Int32 = 128

  /// The number of tab-separated fields a `--verbose` output line holds: the
  /// `source:line:pattern` prefix, then the path.
  static let fieldCount = 2

  /// The number of colon-separated fields the prefix of a matching line holds:
  /// the source, the line number, then the pattern.
  static let prefixFieldCount = 3

  /// The prefix git writes for a path no rule matched, under `--non-matching`.
  static let nonMatchingPrefix = "::"

  /// Reads the `git --version` line of the git this run uses.
  ///
  /// - Parameter scratchDirectory: A directory the run may write its
  ///   standard-error capture file into.
  /// - Returns: git's own version line, such as `git version 2.55.0`.
  /// - Throws: `FixtureError` if git cannot be run or exits non-zero.
  static func version(scratchDirectory: URL) throws -> String {
    let outcome = try Subprocess.run(
      arguments: ["git", "--version"], currentDirectory: scratchDirectory,
      scratchDirectory: scratchDirectory)
    guard outcome.terminationStatus == EXIT_SUCCESS else {
      throw FixtureError(message: "git --version exited \(outcome.terminationStatus)")
    }
    return outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Runs `git check-ignore --verbose --non-matching --stdin` over `probePaths`
  /// inside `repository` and parses its output.
  ///
  /// The probe paths go in through a file rather than a pipe, so the run holds
  /// exactly one pipe and cannot deadlock however much either stream writes.
  ///
  /// - Parameters:
  ///   - probePaths: The paths to probe, one per line on git's standard input.
  ///   - repository: The repository to run inside.
  ///   - scratchDirectory: A directory this call may write its input file into.
  /// - Returns: One verdict per probed path, keyed by path.
  /// - Throws: `FixtureError` if git exits fatally or writes a line that cannot
  ///   be parsed.
  static func verdicts(
    forProbePaths probePaths: [String], in repository: ScratchRepository, scratchDirectory: URL
  ) throws -> [String: GitVerdict] {
    let inputURL = scratchDirectory.appendingPathComponent("probes-\(UUID().uuidString).txt")
    try Data(probePaths.map { $0 + "\n" }.joined().utf8).write(to: inputURL)
    defer { try? FileManager.default.removeItem(at: inputURL) }

    let outcome = try Subprocess.run(
      arguments: ["git", "check-ignore", "--verbose", "--non-matching", "--stdin"],
      currentDirectory: repository.root, standardInputFile: inputURL,
      scratchDirectory: scratchDirectory)

    guard outcome.terminationStatus != fatalStatus else {
      throw FixtureError(
        message: "git check-ignore exited \(fatalStatus): \(outcome.standardError)")
    }

    return try parse(output: outcome.standardOutput)
  }

  /// Parses `git check-ignore --verbose --non-matching`'s tab-separated output:
  /// one `source:line:pattern<TAB>path` line per matching probe, or
  /// `::<TAB>path` for a non-matching one.
  ///
  /// - Parameter output: Everything git wrote to standard output.
  /// - Returns: One verdict per reported path, keyed by path.
  /// - Throws: `FixtureError` on any line that does not hold that shape.
  static func parse(output: String) throws -> [String: GitVerdict] {
    let verdicts = try output.split(separator: "\n", omittingEmptySubsequences: true)
      .map { try parse(line: $0) }
    return Dictionary(verdicts.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
  }

  /// Parses one output line into a verdict.
  ///
  /// - Parameter line: One line of git's standard output, without its newline.
  /// - Returns: The verdict the line states.
  /// - Throws: `FixtureError` if the line does not hold the documented shape.
  private static func parse(line: Substring) throws -> GitVerdict {
    let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    guard fields.count == fieldCount else {
      throw FixtureError(message: "unparseable git check-ignore line: \(line)")
    }
    let prefix = fields[0]
    let path = String(fields[1])

    guard prefix != nonMatchingPrefix else {
      return GitVerdict(path: path, isIgnored: false, source: nil, line: nil, pattern: nil)
    }

    // The pattern itself may hold colons, so the split stops after the line
    // number and leaves the pattern whole as the last field.
    let prefixFields = prefix.split(
      separator: ":", maxSplits: prefixFieldCount - 1, omittingEmptySubsequences: false)
    guard prefixFields.count == prefixFieldCount, let source = prefixFields.first,
      let lineNumber = Int(prefixFields[1]), let patternField = prefixFields.last
    else {
      throw FixtureError(message: "unparseable git check-ignore prefix: \(prefix)")
    }
    let pattern = String(patternField)

    return GitVerdict(
      path: path, isIgnored: !pattern.hasPrefix("!"), source: String(source),
      line: lineNumber, pattern: pattern)
  }
}
