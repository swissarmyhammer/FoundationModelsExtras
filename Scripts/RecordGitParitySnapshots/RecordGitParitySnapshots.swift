import FixtureSupport
import Foundation

/// Records what `git check-ignore --verbose --non-matching` answers for every
/// ignore-parity suite, and writes each answer to the checked-in JSON snapshot
/// the test suite compares against.
///
/// Run it from anywhere in a checkout:
///
///     swift run record-git-parity-snapshots
///
/// This tool is the only place the project starts a `git` process for ignore
/// parity. `swift test` reads the snapshots and starts nothing, so the parity
/// claim needs no `git` on `PATH` and no conditional trait that silently turns
/// a test off.
///
/// Run it again after a git upgrade and read the diff: a changed verdict is
/// either a real change in git's behaviour or a defect, and either way a person
/// decides. Two runs on one day leave the snapshots byte-identical.
@main
struct RecordGitParitySnapshots {
  /// Records every suite, or reports what stopped the run and exits non-zero.
  static func main() {
    do {
      try recordEverySuite()
    } catch {
      Report.write("record-git-parity-snapshots: \(error)")
      exit(EXIT_FAILURE)
    }
  }

  /// Records every suite `IgnoreParitySuite.all` names, into one throwaway
  /// scratch directory that the run removes on its way out.
  ///
  /// - Throws: `FixtureError` if git cannot be run, and whatever the recording
  ///   of any one suite raises.
  private static func recordEverySuite() throws {
    // The temporary directory itself is canonicalized — it exists, so
    // `realpath(3)` can resolve it — and the run's own directory hangs off the
    // resolved form.
    let scratchDirectory = FileManager.default.temporaryDirectory.canonicalDirectory
      .appendingPathComponent("record-git-parity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: scratchDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratchDirectory) }

    let gitVersion = try GitCheckIgnore.version(scratchDirectory: scratchDirectory)
    let recordedOn = todayStamp()
    Report.write("recording with \(gitVersion) on \(recordedOn)")

    for suite in IgnoreParitySuite.all {
      try record(
        suite: suite, gitVersion: gitVersion, recordedOn: recordedOn,
        scratchDirectory: scratchDirectory)
    }
  }

  /// Records one suite: builds its repository, asks git, and writes the
  /// snapshot.
  ///
  /// - Parameters:
  ///   - suite: The suite to record.
  ///   - gitVersion: The `git --version` line to stamp into the snapshot.
  ///   - recordedOn: The `yyyy-MM-dd` stamp to write.
  ///   - scratchDirectory: The directory the temporary repository is built in.
  /// - Throws: `FixtureError` if git reports no verdict for a probe path, and
  ///   whatever the steps above raise.
  private static func record(
    suite: IgnoreParitySuite, gitVersion: String, recordedOn: String, scratchDirectory: URL
  ) throws {
    let repository = try ScratchRepository.materialize(
      suite: suite, scratchDirectory: scratchDirectory)

    let verdictsByPath = try GitCheckIgnore.verdicts(
      forProbePaths: suite.probePaths, in: repository, scratchDirectory: scratchDirectory)

    let verdicts = try suite.probePaths.map { probePath -> GitVerdict in
      guard let verdict = verdictsByPath[probePath] else {
        throw FixtureError(
          message: "git reported no result at all for probe \(probePath) of \(suite.name)")
      }
      return verdict
    }
    .sorted { $0.path < $1.path }

    let snapshot = GitVerdictSnapshot(
      recordedWith: gitVersion, recordedOn: recordedOn, verdicts: verdicts)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snapshot) + Data("\n".utf8)
    try data.write(to: FixtureFile.url(suite.snapshotPath))

    Report.write("recorded \(verdicts.count) verdicts for \(suite.name) -> \(suite.snapshotPath)")
  }

  /// Today's date as `yyyy-MM-dd`, in the POSIX locale and the current time
  /// zone.
  ///
  /// - Returns: The formatted date.
  private static func todayStamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }
}

/// The recorder's narration.
///
/// Progress and failures both go to standard error, so the tool writes nothing
/// to standard out and a caller can silence the narration without losing the
/// snapshots.
enum Report {
  /// Writes one line to standard error.
  ///
  /// - Parameter message: The line to write, without its newline.
  static func write(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
