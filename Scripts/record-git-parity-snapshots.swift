#!/usr/bin/env swift
//
// record-git-parity-snapshots.swift
//
// Records what `git check-ignore --verbose --non-matching` answers for the
// two ignore-parity fixture suites, and writes each answer to a checked-in
// JSON snapshot the test suite compares against.
//
// Run it from the repository root:
//
//     swift Scripts/record-git-parity-snapshots.swift
//
// This is the ONLY place the project starts a `git` process for ignore
// parity. `swift test` reads the snapshots and starts nothing, so the parity
// claim needs no `git` on `PATH` and no conditional trait that silently
// turns a test off.
//
// Re-run it after a git upgrade and read the diff: a changed verdict is
// either a real change in git's behaviour or a defect, and either way a
// person decides. Running it twice on one day leaves the snapshots
// byte-identical.
//

import Foundation

// MARK: - Errors

/// A failure of the recorder itself — a `git` process that would not run, or
/// output that could not be parsed. Never an `IgnoreProcessor` failure: this
/// script does not link the library at all.
struct RecorderError: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

// MARK: - Subprocess plumbing

/// One finished subprocess: what it wrote, and how it exited.
struct ProcessOutcome {
  /// Everything the process wrote to standard output, decoded as UTF-8.
  let standardOutput: String
  /// Everything the process wrote to standard error, decoded as UTF-8.
  let standardError: String
  /// The process's exit status.
  let terminationStatus: Int32
}

/// Runs `arguments` (resolved through `/usr/bin/env`, so `git` is found on
/// `PATH`) in `currentDirectory` and collects everything it wrote.
///
/// Standard output is the run's ONE pipe. Standard input and standard error
/// are plain files, so no second pipe exists to fill while this call blocks
/// reading the first — the deadlock a two-pipe sequential read has whenever
/// either stream outgrows its buffer.
///
/// - Parameters:
///   - arguments: The command and its arguments, `arguments[0]` naming the
///     program `/usr/bin/env` resolves.
///   - currentDirectory: The working directory to run in.
///   - standardInputFile: A file to feed the process on standard input, or
///     `nil` to give it no input at all.
///   - scratchDirectory: A directory this call may write its standard-error
///     capture file into.
/// - Returns: What the process wrote, and its exit status.
/// - Throws: `RecorderError` if the process cannot be launched, or if its
///   standard-error capture file cannot be created or reopened.
func run(
  arguments: [String],
  currentDirectory: URL,
  standardInputFile: URL? = nil,
  scratchDirectory: URL
) throws -> ProcessOutcome {
  let errorFileURL = scratchDirectory.appendingPathComponent("stderr-\(UUID().uuidString).txt")
  guard FileManager.default.createFile(atPath: errorFileURL.path, contents: nil) else {
    throw RecorderError(message: "could not create \(errorFileURL.path)")
  }
  guard let errorHandle = FileHandle(forWritingAtPath: errorFileURL.path) else {
    throw RecorderError(message: "could not open \(errorFileURL.path) for writing")
  }
  defer { try? FileManager.default.removeItem(at: errorFileURL) }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = arguments
  process.currentDirectoryURL = currentDirectory
  process.standardError = errorHandle

  let outputPipe = Pipe()
  process.standardOutput = outputPipe

  if let standardInputFile {
    guard let inputHandle = FileHandle(forReadingAtPath: standardInputFile.path) else {
      throw RecorderError(message: "could not open \(standardInputFile.path) for reading")
    }
    process.standardInput = inputHandle
  }

  do {
    try process.run()
  } catch {
    throw RecorderError(
      message: "could not run \(arguments.joined(separator: " ")): \(error)")
  }

  let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  try? errorHandle.close()

  let errorData = (try? Data(contentsOf: errorFileURL)) ?? Data()
  return ProcessOutcome(
    standardOutput: String(decoding: outputData, as: UTF8.self),
    standardError: String(decoding: errorData, as: UTF8.self),
    terminationStatus: process.terminationStatus)
}

/// Runs `arguments` in `currentDirectory` and throws unless it exits zero —
/// for the setup steps whose output nothing reads.
///
/// - Parameters:
///   - arguments: The command and its arguments.
///   - currentDirectory: The working directory to run in.
///   - scratchDirectory: A directory the run may write its standard-error
///     capture file into.
/// - Throws: `RecorderError` if the process cannot be launched or exits
///   non-zero.
func runExpectingSuccess(
  arguments: [String], currentDirectory: URL, scratchDirectory: URL
) throws {
  let outcome = try run(
    arguments: arguments, currentDirectory: currentDirectory,
    scratchDirectory: scratchDirectory)
  guard outcome.terminationStatus == 0 else {
    throw RecorderError(
      message: """
        \(arguments.joined(separator: " ")) exited \(outcome.terminationStatus): \
        \(outcome.standardError)
        """)
  }
}

/// Resolves `url` to its real, symlink- and firmlink-free path via POSIX
/// `realpath(3)`.
///
/// The temporary directory is reached through a firmlink on macOS, and git
/// reports paths under the resolved form, so the repository root is resolved
/// once up front.
///
/// - Parameter url: The directory URL to resolve.
/// - Returns: The resolved directory URL, or `url` unchanged when
///   `realpath(3)` fails.
func canonicalize(_ url: URL) -> URL {
  var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
  guard realpath(url.path, &buffer) != nil else { return url }
  let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
  let path = String(
    decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
  return URL(fileURLWithPath: path, isDirectory: true)
}

// MARK: - The snapshot format

/// One path's outcome as `git check-ignore --verbose --non-matching`
/// reported it.
///
/// `source`, `line` and `pattern` are absent when git matched no rule at all
/// — its `::` output — so a decoded verdict that carries none of the three
/// is git saying "nothing decided this path".
struct GitVerdict: Codable {
  /// The probed path, in the same trailing-slash-means-directory form
  /// `IgnoreProcessor.evaluate` and `git check-ignore` both use.
  let path: String
  /// Whether git considers the path ignored: it matched a pattern that does
  /// not begin with `!`.
  let isIgnored: Bool
  /// The file git attributes the deciding pattern to (`.gitignore`,
  /// `.git/info/exclude`), or `nil` when no rule matched.
  let source: String?
  /// The deciding pattern's 1-based line number in `source`, or `nil` when
  /// no rule matched.
  let line: Int?
  /// The deciding pattern's raw text, including any `!` negation prefix, or
  /// `nil` when no rule matched.
  let pattern: String?
}

/// One suite's whole recorded answer, with the provenance that makes it
/// reproducible.
struct GitVerdictSnapshot: Codable {
  /// The `git --version` line of the run that recorded this file.
  let recordedWith: String
  /// The day the recording ran, as `yyyy-MM-dd`.
  let recordedOn: String
  /// Every probed path's verdict, sorted by `path` so a later recording
  /// gives a diff a person can read.
  let verdicts: [GitVerdict]
}

// MARK: - The suites this script records

/// One parity suite: the ignore files to materialize, the paths to probe,
/// and where the snapshot goes.
///
/// Every path is stated relative to the package root.
struct SnapshotSuite {
  /// The suite's name, used in progress output only.
  let name: String
  /// The fixture whose contents become the repository's `.gitignore`.
  let gitignoreFixture: String
  /// The fixture whose contents overwrite the repository's
  /// `.git/info/exclude`, or `nil` for a suite with no exclude layer.
  ///
  /// `git init` seeds that file with template comments, so a suite that
  /// uses it overwrites the file rather than appending — the line numbers
  /// git reports have to be the line numbers of the fixture.
  let excludeFixture: String?
  /// The paths to probe. This list mirrors the suite's own `probes` table in
  /// the test file; the test asserts the snapshot holds a verdict for every
  /// path it probes, so a path added on one side and not the other fails the
  /// suite rather than passing in silence.
  let probePaths: [String]
  /// Where the recorded snapshot is written.
  let snapshotFixture: String
}

/// The corpus suite's probe paths. Mirrors `IgnoreGitParityTests.probes`.
let corpusProbePaths = [
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

  // Parent exclusion: a later rule cannot re-include a named descendant of
  // an excluded directory.
  "blocked/reachable.txt",
  "blocked/other.txt",
  "blocked/",

  // Parent exclusion lifted: re-including the ancestor itself lets a later
  // rule reach its descendants again.
  "lifted/thing.scratch",
  "lifted/other.txt",

  // Plain default-include paths and bare directory probes with no rule of
  // their own.
  "src/main.swift",
  "README.md",
  "notbuild.txt",
  "a/",
  "sub/",
  "deep/nested/",
]

/// The combination suite's probe paths. Mirrors
/// `IgnoreProcessorCombinationGitParityTests.probePaths`.
let combinationProbePaths = [
  "important.log", "debug.log", "build/x.o", "readme.md",
]

/// Every suite this script records, in the order it records them.
let suites = [
  SnapshotSuite(
    name: "ignore-corpus",
    gitignoreFixture: "Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/gitignore.txt",
    excludeFixture: nil,
    probePaths: corpusProbePaths,
    snapshotFixture:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-corpus/git-verdicts.json"),
  SnapshotSuite(
    name: "ignore-combination",
    gitignoreFixture:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/gitignore.txt",
    excludeFixture:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/exclude.txt",
    probePaths: combinationProbePaths,
    snapshotFixture:
      "Tests/FoundationModelsExtrasTests/Fixtures/ignore-combination/git-verdicts.json"),
]

// MARK: - Materializing a repository

/// Creates one probe path under `repositoryRoot`: a directory for a
/// trailing-slash path, an empty file otherwise.
///
/// Intermediate parent directories are created either way.
///
/// - Parameters:
///   - probePath: The relative probe path to create.
///   - repositoryRoot: The repository the path is created under.
/// - Throws: Whatever `FileManager` raises when a directory cannot be
///   created.
func materialize(probePath: String, under repositoryRoot: URL) throws {
  let isDirectory = probePath.hasSuffix("/")
  let trimmed = isDirectory ? String(probePath.dropLast()) : probePath
  guard !trimmed.isEmpty else { return }

  let fullURL = repositoryRoot.appendingPathComponent(trimmed)
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

/// Builds a real git repository for `suite` inside `scratchDirectory`: `git
/// init`, the ignore files written from their fixtures, and every probe path
/// created on disk.
///
/// - Parameters:
///   - suite: The suite to materialize.
///   - packageRoot: The package root the suite's fixture paths resolve
///     against.
///   - scratchDirectory: The directory the repository is created inside.
/// - Returns: The repository's root URL.
/// - Throws: `RecorderError` if a fixture cannot be read or `git init`
///   fails, and whatever `FileManager` raises on a write.
func materializeRepository(
  for suite: SnapshotSuite, packageRoot: URL, scratchDirectory: URL
) throws -> URL {
  let repositoryURL = scratchDirectory.appendingPathComponent(
    "repo-\(suite.name)", isDirectory: true)
  try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

  try runExpectingSuccess(
    arguments: ["git", "init", "-q"], currentDirectory: repositoryURL,
    scratchDirectory: scratchDirectory)

  try readFixture(suite.gitignoreFixture, under: packageRoot)
    .write(
      to: repositoryURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

  if let excludeFixture = suite.excludeFixture {
    try readFixture(excludeFixture, under: packageRoot)
      .write(
        to: repositoryURL.appendingPathComponent(".git/info/exclude"), atomically: true,
        encoding: .utf8)
  }

  for probePath in suite.probePaths {
    try materialize(probePath: probePath, under: repositoryURL)
  }

  return repositoryURL
}

/// Reads one checked-in fixture as UTF-8 text.
///
/// - Parameters:
///   - relativePath: The fixture's path relative to `packageRoot`.
///   - packageRoot: The package root.
/// - Returns: The fixture's contents.
/// - Throws: `RecorderError` if the fixture is missing or not valid UTF-8.
func readFixture(_ relativePath: String, under packageRoot: URL) throws -> String {
  let url = packageRoot.appendingPathComponent(relativePath)
  guard let text = try? String(contentsOf: url, encoding: .utf8) else {
    throw RecorderError(message: "could not read fixture at \(url.path)")
  }
  return text
}

// MARK: - Asking git

/// The exit status `git check-ignore` uses for a fatal error, as distinct
/// from `0` (something matched) and `1` (nothing matched) — both of which
/// are normal runs.
let gitCheckIgnoreFatalStatus: Int32 = 128

/// The number of tab-separated fields a `git check-ignore --verbose` line
/// holds: the `source:line:pattern` prefix, then the path.
let gitCheckIgnoreFieldCount = 2

/// Runs `git check-ignore --verbose --non-matching --stdin` over
/// `probePaths` inside `repositoryURL` and parses its output.
///
/// The probe paths go in through a file rather than a pipe, so the run holds
/// exactly one pipe and cannot deadlock however much either stream writes.
///
/// - Parameters:
///   - probePaths: The paths to probe, one per line on git's standard input.
///   - repositoryURL: The repository to run inside.
///   - scratchDirectory: A directory this call may write its input file
///     into.
/// - Returns: One verdict per probe path, keyed by path.
/// - Throws: `RecorderError` if git exits `128` or writes a line that cannot
///   be parsed.
func runCheckIgnore(
  probePaths: [String], repositoryURL: URL, scratchDirectory: URL
) throws -> [String: GitVerdict] {
  let inputURL = scratchDirectory.appendingPathComponent("probes-\(UUID().uuidString).txt")
  try Data(probePaths.map { $0 + "\n" }.joined().utf8).write(to: inputURL)
  defer { try? FileManager.default.removeItem(at: inputURL) }

  let outcome = try run(
    arguments: ["git", "check-ignore", "--verbose", "--non-matching", "--stdin"],
    currentDirectory: repositoryURL, standardInputFile: inputURL,
    scratchDirectory: scratchDirectory)

  guard outcome.terminationStatus != gitCheckIgnoreFatalStatus else {
    throw RecorderError(
      message: "git check-ignore exited \(gitCheckIgnoreFatalStatus): \(outcome.standardError)")
  }

  return try parseCheckIgnore(output: outcome.standardOutput)
}

/// Parses `git check-ignore --verbose --non-matching`'s tab-separated
/// output: one `source:line:pattern<TAB>path` line per matching probe, or
/// `::<TAB>path` for a non-matching one.
///
/// - Parameter output: Everything git wrote to standard output.
/// - Returns: One verdict per reported path, keyed by path.
/// - Throws: `RecorderError` on any line that does not hold that shape.
func parseCheckIgnore(output: String) throws -> [String: GitVerdict] {
  var results: [String: GitVerdict] = [:]
  for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
    let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    guard fields.count == gitCheckIgnoreFieldCount else {
      throw RecorderError(message: "unparseable git check-ignore line: \(line)")
    }
    let left = String(fields[0])
    let path = String(fields[1])

    guard left != "::" else {
      results[path] = GitVerdict(
        path: path, isIgnored: false, source: nil, line: nil, pattern: nil)
      continue
    }

    guard let firstColon = left.firstIndex(of: ":") else {
      throw RecorderError(message: "unparseable git check-ignore prefix: \(left)")
    }
    let source = String(left[left.startIndex..<firstColon])
    let afterFirst = left.index(after: firstColon)
    guard let secondColon = left[afterFirst...].firstIndex(of: ":") else {
      throw RecorderError(message: "unparseable git check-ignore prefix: \(left)")
    }
    let lineText = String(left[afterFirst..<secondColon])
    let pattern = String(left[left.index(after: secondColon)...])
    guard let lineNumber = Int(lineText) else {
      throw RecorderError(message: "unparseable git check-ignore line number: \(left)")
    }

    results[path] = GitVerdict(
      path: path, isIgnored: !pattern.hasPrefix("!"), source: source, line: lineNumber,
      pattern: pattern)
  }
  return results
}

// MARK: - Recording

/// Reads the `git --version` line of the git this run uses.
///
/// - Parameter scratchDirectory: A directory the run may write its
///   standard-error capture file into.
/// - Returns: git's own version line, e.g. `git version 2.55.0`.
/// - Throws: `RecorderError` if git cannot be run or exits non-zero.
func readGitVersion(scratchDirectory: URL) throws -> String {
  let outcome = try run(
    arguments: ["git", "--version"], currentDirectory: scratchDirectory,
    scratchDirectory: scratchDirectory)
  guard outcome.terminationStatus == 0 else {
    throw RecorderError(message: "git --version exited \(outcome.terminationStatus)")
  }
  return outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Today's date as `yyyy-MM-dd`, in the POSIX locale and the current time
/// zone.
///
/// - Returns: The formatted date.
func todayStamp() -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter.string(from: Date())
}

/// Records one suite: materializes its repository, asks git, and writes the
/// snapshot.
///
/// - Parameters:
///   - suite: The suite to record.
///   - packageRoot: The package root every fixture path resolves against.
///   - gitVersion: The `git --version` line to stamp into the snapshot.
///   - recordedOn: The `yyyy-MM-dd` stamp to write.
///   - scratchDirectory: The directory the temporary repository is built in.
/// - Throws: `RecorderError` if git reports no verdict for a probe path, and
///   whatever the steps above raise.
func record(
  suite: SnapshotSuite, packageRoot: URL, gitVersion: String, recordedOn: String,
  scratchDirectory: URL
) throws {
  let repositoryURL = try materializeRepository(
    for: suite, packageRoot: packageRoot, scratchDirectory: scratchDirectory)

  let verdictsByPath = try runCheckIgnore(
    probePaths: suite.probePaths, repositoryURL: repositoryURL,
    scratchDirectory: scratchDirectory)

  var verdicts: [GitVerdict] = []
  for probePath in suite.probePaths {
    guard let verdict = verdictsByPath[probePath] else {
      throw RecorderError(
        message: "git reported no result at all for probe \(probePath) of \(suite.name)")
    }
    verdicts.append(verdict)
  }
  verdicts.sort { $0.path < $1.path }

  let snapshot = GitVerdictSnapshot(
    recordedWith: gitVersion, recordedOn: recordedOn, verdicts: verdicts)

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  var data = try encoder.encode(snapshot)
  data.append(contentsOf: "\n".utf8)

  let snapshotURL = packageRoot.appendingPathComponent(suite.snapshotFixture)
  try data.write(to: snapshotURL)
  print("recorded \(verdicts.count) verdicts for \(suite.name) -> \(suite.snapshotFixture)")
}

// MARK: - Entry point

/// The package root, derived from this script's own path (`Scripts/` sits
/// one level below it) and resolved against the working directory, so the
/// script works whichever directory it is started from.
let packageRoot = URL(
  fileURLWithPath: #filePath,
  relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
)
.deletingLastPathComponent()  // record-git-parity-snapshots.swift -> Scripts/
.deletingLastPathComponent()  // Scripts/ -> package root

// The temporary directory itself is canonicalized — it exists, so
// `realpath(3)` can resolve it — and the run's own directory hangs off the
// resolved form.
let scratchDirectory = canonicalize(FileManager.default.temporaryDirectory)
  .appendingPathComponent("record-git-parity-\(UUID().uuidString)", isDirectory: true)

do {
  try FileManager.default.createDirectory(
    at: scratchDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: scratchDirectory) }

  let gitVersion = try readGitVersion(scratchDirectory: scratchDirectory)
  let recordedOn = todayStamp()
  print("recording with \(gitVersion) on \(recordedOn)")

  for suite in suites {
    try record(
      suite: suite, packageRoot: packageRoot, gitVersion: gitVersion, recordedOn: recordedOn,
      scratchDirectory: scratchDirectory)
  }
} catch {
  FileHandle.standardError.write(Data("record-git-parity-snapshots: \(error)\n".utf8))
  exit(1)
}
