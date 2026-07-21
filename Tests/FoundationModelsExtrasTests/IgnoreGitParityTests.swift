import Foundation
import Testing

@testable import FoundationModelsExtras

/// Corpus-level parity checks for `IgnoreProcessor`: a checked-in ~40-path
/// probe table exercises every pattern-surface bullet from the
/// `IgnoreRule`/`Wildmatch`/`IgnoreProcessor` tasks (comments, escapes,
/// CRLF lines, negation, anchoring, dir-only rules, `*`/`?`, bracket and
/// POSIX character classes, all three `**` forms, and parent-exclusion
/// setups), against the fixture at
/// `Fixtures/ignore-corpus/gitignore.txt`.
///
/// Test 1 always runs and needs no external tooling: it checks
/// `IgnoreProcessor`'s verdicts against the checked-in expectations below.
/// Test 2 (gated on `git` being on `PATH`) replays the same probes through
/// a real, materialized git repository via `git check-ignore --verbose
/// --non-matching --stdin`, proving our matcher agrees with git itself —
/// both on ignored/included status and on the deciding rule's line number,
/// where git reports one.
@Suite struct IgnoreGitParityTests {

  // MARK: - Probe corpus

  /// One relative path probed against the corpus fixture, with its
  /// checked-in expected outcome. `path` follows the same
  /// trailing-slash-means-directory convention `IgnoreProcessor.evaluate`
  /// and `git check-ignore` both use.
  struct Probe: Sendable, CustomStringConvertible {
    let path: String
    let isIgnored: Bool
    /// The 1-based line in `gitignore.txt` whose rule decides this probe's
    /// verdict, or `nil` when no rule matches (default include).
    let decidingLine: Int?

    var description: String { path }
  }

  /// The probe corpus. Every path is materializable on disk without
  /// conflict (no path is asked to be both a file and a directory), which
  /// Test 2 depends on when it builds a real git repository from this same
  /// list. See `Fixtures/ignore-corpus/gitignore.txt` for the rules that
  /// decide each of these.
  static let probes: [Probe] = [
    // Comments, escapes, and trailing-space handling.
    Probe(path: "#hashfile.txt", isIgnored: true, decidingLine: 6),
    Probe(path: "!bangfile.txt", isIgnored: true, decidingLine: 9),
    Probe(path: "escapedspace ", isIgnored: true, decidingLine: 12),
    Probe(path: "escapedspace", isIgnored: false, decidingLine: nil),

    // Basic wildcard with a negated re-include.
    Probe(path: "keep.log", isIgnored: false, decidingLine: 16),
    Probe(path: "other.log", isIgnored: true, decidingLine: 15),
    Probe(path: "deep/nested/other.log", isIgnored: true, decidingLine: 15),
    Probe(path: "nested/keep.log", isIgnored: false, decidingLine: 16),

    // Anchoring.
    Probe(path: "anchored.txt", isIgnored: true, decidingLine: 19),
    Probe(path: "sub/anchored.txt", isIgnored: false, decidingLine: nil),

    // Directory-only rule + parent-directory exclusion.
    Probe(path: "build/output.bin", isIgnored: true, decidingLine: 22),
    Probe(path: "build/", isIgnored: true, decidingLine: 22),
    Probe(path: "sub/build/x.bin", isIgnored: true, decidingLine: 22),
    Probe(path: "sub/build/", isIgnored: true, decidingLine: 22),

    // Single-character wildcard.
    Probe(path: "fileA.txt", isIgnored: true, decidingLine: 25),
    Probe(path: "fileAB.txt", isIgnored: false, decidingLine: nil),

    // Bracket character classes: `[!...]` and `[^...]` negation spellings.
    Probe(path: "xbracket.txt", isIgnored: true, decidingLine: 28),
    Probe(path: "abracket.txt", isIgnored: false, decidingLine: nil),
    Probe(path: "acaret.txt", isIgnored: true, decidingLine: 31),
    Probe(path: "xcaret.txt", isIgnored: false, decidingLine: nil),

    // Named POSIX character class.
    Probe(path: "digit5.txt", isIgnored: true, decidingLine: 34),
    Probe(path: "digitA.txt", isIgnored: false, decidingLine: nil),
    Probe(path: "digit10.txt", isIgnored: false, decidingLine: nil),

    // Leading `**` — matches the same basename at any depth.
    Probe(path: "deep.tmp", isIgnored: true, decidingLine: 37),
    Probe(path: "a/b/deep.tmp", isIgnored: true, decidingLine: 37),

    // Interior `**` — zero or more path segments.
    Probe(path: "mid/inner.txt", isIgnored: true, decidingLine: 40),
    Probe(path: "mid/x/inner.txt", isIgnored: true, decidingLine: 40),
    Probe(path: "mid/x/y/inner.txt", isIgnored: true, decidingLine: 40),

    // Trailing `**` — everything inside, one or more segments.
    Probe(path: "logs/a.txt", isIgnored: true, decidingLine: 43),

    // Parent exclusion: a later rule cannot re-include a named descendant
    // of an excluded directory.
    Probe(path: "blocked/reachable.txt", isIgnored: true, decidingLine: 47),
    Probe(path: "blocked/other.txt", isIgnored: true, decidingLine: 47),
    Probe(path: "blocked/", isIgnored: true, decidingLine: 47),

    // Parent exclusion lifted: re-including the ancestor itself lets a
    // later rule reach its descendants again.
    Probe(path: "lifted/thing.scratch", isIgnored: true, decidingLine: 54),
    Probe(path: "lifted/other.txt", isIgnored: false, decidingLine: nil),

    // Plain default-include paths and bare directory probes with no rule
    // of their own.
    Probe(path: "src/main.swift", isIgnored: false, decidingLine: nil),
    Probe(path: "README.md", isIgnored: false, decidingLine: nil),
    Probe(path: "notbuild.txt", isIgnored: false, decidingLine: nil),
    Probe(path: "a/", isIgnored: false, decidingLine: nil),
    Probe(path: "sub/", isIgnored: false, decidingLine: nil),
    Probe(path: "deep/nested/", isIgnored: false, decidingLine: nil),
  ]

  /// The checked-in corpus fixture, resolved relative to the package root
  /// (this file lives three levels below it, same as every file in this
  /// test target — see `PackageRootValidation`).
  static let fixtureURL =
    PackageRootValidation.packageRoot()
    .appendingPathComponent(
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/gitignore.txt")

  static let processor: IgnoreProcessor = {
    guard let processor = try? IgnoreProcessor(contentsOf: fixtureURL) else {
      fatalError("failed to load ignore-corpus fixture at \(fixtureURL.path)")
    }
    return processor
  }()

  /// Projects a verdict down to the deciding rule's line number, or `nil`
  /// if nothing decided it — the field both Test 1 and Test 2 compare.
  private static func decidingLine(of verdict: IgnoreVerdict) -> Int? {
    switch verdict.reason {
    case .matched(let rule): return rule.line
    case .parentExcluded(_, let rule): return rule.line
    case .noRuleMatched: return nil
    }
  }

  // MARK: - Test 1: table-driven, no git required

  @Test(arguments: probes) func verdictMatchesCheckedInExpectation(_ probe: Probe) {
    let verdict = Self.processor.evaluate(probe.path)

    #expect(verdict.isIgnored == probe.isIgnored, "probe \(probe.path): \(verdict)")
    #expect(
      Self.decidingLine(of: verdict) == probe.decidingLine,
      "probe \(probe.path): \(verdict)")
  }

  // MARK: - Test 2: git parity

  @Test(.enabled(if: GitParityHarness.isGitAvailable()))
  func verdictMatchesGitCheckIgnoreVerbose() throws {
    let gitignoreContents = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
    let repoURL = try GitParityHarness.materializeRepo(
      gitignoreContents: gitignoreContents, probePaths: Self.probes.map(\.path))
    defer { try? FileManager.default.removeItem(at: repoURL) }

    let gitVerdicts = try GitParityHarness.runCheckIgnore(
      probePaths: Self.probes.map(\.path), repoURL: repoURL)

    for probe in Self.probes {
      let ours = Self.processor.evaluate(probe.path)
      guard let git = gitVerdicts[probe.path] else {
        Issue.record("git reported no result at all for probe \(probe.path)")
        continue
      }

      #expect(
        ours.isIgnored == git.isIgnored,
        "probe \(probe.path): ours=\(ours) git=\(git)")
      if let gitLine = git.line {
        #expect(
          Self.decidingLine(of: ours) == gitLine,
          "probe \(probe.path): ours=\(ours) git=\(git)")
      }
    }
  }
}

// MARK: - Git subprocess + repo-materialization harness

/// Reusable plumbing for git-parity tests: materializes a checked-in
/// gitignore-syntax fixture as a real git repository and replays `git
/// check-ignore --verbose --non-matching` over a probe list, for comparison
/// against an `IgnoreProcessor`'s own verdicts.
///
/// Deliberately not `private`/`fileprivate`: a later task's own git-parity
/// test (for the ignore-file `+` combination operator) reuses this exact
/// plumbing against its own fixture and probe list.
enum GitParityHarness {

  /// One path's outcome as reported by `git check-ignore --verbose`.
  struct GitVerdict: Sendable, CustomStringConvertible {
    /// `true` when git considers the path ignored: it matched a pattern
    /// that does not begin with `!`.
    let isIgnored: Bool
    /// The deciding pattern's 1-based line number in the ignore file, or
    /// `nil` when git reports no matching pattern at all (`::`).
    let line: Int?
    let source: String?
    let pattern: String?

    var description: String {
      guard let source, let line, let pattern else { return "no match" }
      return "\(source):\(line):\(pattern)"
    }
  }

  /// Errors raised by the git subprocess helpers themselves — never by
  /// `IgnoreProcessor`, which has its own error type. This one is purely
  /// about driving `git` as an external tool.
  struct GitProcessError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  /// Reports whether a `git` binary is reachable on `PATH`, for gating a
  /// parity test with a Swift Testing conditional trait. Never throws —
  /// any failure to even launch the probe process is treated as "git is not
  /// available" so the caller can skip cleanly instead of failing.
  static func isGitAvailable() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "git"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  /// Materializes `gitignoreContents` as `.gitignore` inside a fresh `git
  /// init`-ed temp directory, then creates every probe path on disk: a
  /// directory (including intermediate parents) for a path ending in `/`,
  /// or an empty file (creating intermediate parent directories first)
  /// otherwise — the same trailing-slash convention
  /// `IgnoreProcessor.evaluate` and `git check-ignore` both use.
  ///
  /// - Returns: The repository's root URL. The caller owns cleanup.
  static func materializeRepo(
    gitignoreContents: String, probePaths: [String]
  ) throws -> URL {
    let repoURL = canonicalize(
      FileManager.default.temporaryDirectory
        .appendingPathComponent("ignore-git-parity-\(UUID().uuidString)", isDirectory: true))
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

    try run(arguments: ["git", "init", "-q"], currentDirectory: repoURL)

    let gitignoreURL = repoURL.appendingPathComponent(".gitignore")
    try gitignoreContents.write(to: gitignoreURL, atomically: true, encoding: .utf8)

    for probePath in probePaths {
      try materialize(probePath, under: repoURL)
    }

    return repoURL
  }

  /// Creates one probe path under `repoRoot`: a directory for a
  /// trailing-slash path, an empty file otherwise. Intermediate parent
  /// directories are created either way.
  private static func materialize(_ probePath: String, under repoRoot: URL) throws {
    let isDirectory = probePath.hasSuffix("/")
    let trimmed = isDirectory ? String(probePath.dropLast()) : probePath
    guard !trimmed.isEmpty else { return }

    let fullURL = repoRoot.appendingPathComponent(trimmed)
    if isDirectory {
      try FileManager.default.createDirectory(at: fullURL, withIntermediateDirectories: true)
    } else {
      let parent = fullURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: fullURL.path) {
        FileManager.default.createFile(atPath: fullURL.path, contents: nil)
      }
    }
  }

  /// Runs `git check-ignore --verbose --non-matching --stdin` over
  /// `probePaths` inside `repoURL`, and parses its output into one
  /// `GitVerdict` per probe path.
  ///
  /// - Throws: `GitProcessError` if git exits `128` (a fatal error, not
  ///   "nothing was ignored") or its output can't be parsed. Exit codes `0`
  ///   and `1` both indicate a normal run — `1` just means none of the
  ///   probes were ignored.
  static func runCheckIgnore(
    probePaths: [String], repoURL: URL
  ) throws -> [String: GitVerdict] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "check-ignore", "--verbose", "--non-matching", "--stdin"]
    process.currentDirectoryURL = repoURL

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    let inputData = Data(probePaths.map { $0 + "\n" }.joined().utf8)
    stdinPipe.fileHandleForWriting.write(inputData)
    try? stdinPipe.fileHandleForWriting.close()

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus != 128 else {
      let message = String(decoding: errorData, as: UTF8.self)
      throw GitProcessError(message: "git check-ignore exited 128: \(message)")
    }

    let output = String(decoding: outputData, as: UTF8.self)
    return try parse(output: output)
  }

  /// Parses `git check-ignore --verbose --non-matching`'s tab-separated
  /// output: one `source:line:pattern<TAB>path` line per matching probe, or
  /// `::<TAB>path` for a non-matching one.
  private static func parse(output: String) throws -> [String: GitVerdict] {
    var results: [String: GitVerdict] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard fields.count == 2 else {
        throw GitProcessError(message: "unparseable git check-ignore line: \(line)")
      }
      let left = String(fields[0])
      let path = String(fields[1])

      guard left != "::" else {
        results[path] = GitVerdict(isIgnored: false, line: nil, source: nil, pattern: nil)
        continue
      }

      guard let firstColon = left.firstIndex(of: ":") else {
        throw GitProcessError(message: "unparseable git check-ignore prefix: \(left)")
      }
      let source = String(left[left.startIndex..<firstColon])
      let afterFirst = left.index(after: firstColon)
      guard let secondColon = left[afterFirst...].firstIndex(of: ":") else {
        throw GitProcessError(message: "unparseable git check-ignore prefix: \(left)")
      }
      let lineText = String(left[afterFirst..<secondColon])
      let pattern = String(left[left.index(after: secondColon)...])
      guard let lineNumber = Int(lineText) else {
        throw GitProcessError(message: "unparseable git check-ignore line number: \(left)")
      }

      results[path] = GitVerdict(
        isIgnored: !pattern.hasPrefix("!"), line: lineNumber, source: source, pattern: pattern)
    }
    return results
  }

  /// Runs `git` (via `/usr/bin/env` for `PATH` resolution) with `arguments`
  /// in `currentDirectory`, throwing if it exits non-zero.
  private static func run(arguments: [String], currentDirectory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(
        decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      throw GitProcessError(
        message: "\(arguments.joined(separator: " ")) failed: \(message)")
    }
  }
}
