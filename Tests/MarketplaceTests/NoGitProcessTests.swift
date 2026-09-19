import FixtureSupport
import Foundation
import Testing

/// Guards marketplace.md decision 10: the package never starts the `git`
/// binary. Git work goes through libgit2 behind `GitTransport`.
///
/// The suite reads every Swift file under `Sources/Marketplace`, found from
/// the package root, and reports each line that starts a process and names
/// `git`. A line starts a process when it sets `executableURL` or
/// `launchPath`, or when it builds a `Process`. A line names `git` when one of
/// its words, split at each character that is not a letter or a digit, is
/// `git`. Thus `/usr/bin/git` and `"git"` are reported, and `libgit2` and
/// `GitTransport` are not.
@Suite("No git process")
struct NoGitProcessTests {
  /// The text that marks a line that starts a process: it sets the
  /// executable of a `Process`, or it builds one.
  private static let processMarkers = ["executableURL", "launchPath", "Process("]

  /// The executable that no process line may name.
  private static let gitExecutableName = "git"

  /// The source directory, relative to the package root.
  private static let sourcesPath = "Sources/Marketplace"

  /// The suffix of a Swift source file.
  private static let swiftFileSuffix = ".swift"

  @Test(arguments: [
    #"process.executableURL = URL(fileURLWithPath: "/usr/bin/git")"#,
    #"process.launchPath = "/usr/bin/git""#,
    "let git = Process()",
    "let GIT = Process()",
  ])
  func aProcessLineThatNamesGitIsReported(line: String) {
    #expect(Self.processLinesNamingGit(in: line) == [1])
  }

  @Test(arguments: [
    #"process.executableURL = URL(fileURLWithPath: "/bin/sh")"#,
    "import libgit2",
    "let transport: any GitTransport = LibGit2Transport()",
    #"let note = "the package does not start git""#,
  ])
  func aLineThatDoesNotStartGitIsNotReported(line: String) {
    #expect(Self.processLinesNamingGit(in: line).isEmpty)
  }

  @Test func theReportedLineNumberCountsFromOne() {
    let gitLineNumber = 3
    let text = """
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.launchPath = "/usr/local/bin/git"
      """

    #expect(Self.processLinesNamingGit(in: text) == [gitLineNumber])
  }

  @Test func noFileUnderTheMarketplaceSourcesStartsAGitProcess() throws {
    let sources = FixtureFile.url(Self.sourcesPath)
    let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
      .filter { $0.hasSuffix(Self.swiftFileSuffix) }

    let offenders = try files.flatMap { relativePath in
      let text = try String(contentsOf: sources.appendingPathComponent(relativePath), encoding: .utf8)
      return Self.processLinesNamingGit(in: text).map { "\(Self.sourcesPath)/\(relativePath):\($0)" }
    }

    #expect(!files.isEmpty, "the walk found no Swift file under \(sources.path), thus it proves nothing")
    #expect(
      offenders.isEmpty,
      """
      No file under \(Self.sourcesPath) may start the git binary (marketplace.md decision 10). Use \
      GitTransport, which calls libgit2; found: \(offenders.joined(separator: ", "))
      """)
  }

  /// Finds each line of `text` that starts a process and names `git`.
  ///
  /// - Parameter text: The source text to read.
  /// - Returns: The number of each reported line. The first line is 1.
  private static func processLinesNamingGit(in text: String) -> [Int] {
    text.components(separatedBy: .newlines).enumerated()
      .filter { startsAProcess($0.element) && namesGit($0.element) }
      .map { $0.offset + 1 }
  }

  /// Tells whether `line` sets the executable of a process or builds one.
  private static func startsAProcess(_ line: String) -> Bool {
    processMarkers.contains { line.contains($0) }
  }

  /// Tells whether one word of `line` is `git`, in any letter case.
  private static func namesGit(_ line: String) -> Bool {
    line.split { !$0.isLetter && !$0.isNumber }.contains { $0.lowercased() == gitExecutableName }
  }
}
