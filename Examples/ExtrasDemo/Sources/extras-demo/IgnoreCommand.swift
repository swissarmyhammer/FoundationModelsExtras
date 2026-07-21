import ArgumentParser
import Foundation
import FoundationModelsExtras

/// `extras-demo ignore --file <ignore-file> [--file <ignore-file> ...] <path> [<path> ...]` —
/// evaluates each `path` against the `IgnoreProcessor` built by loading every
/// `--file` and combining them left-to-right with `+`: a later `--file`
/// overrides an earlier one wherever both match, mirroring git's own layered
/// ignore sources (e.g. `.git/info/exclude` then `.gitignore`).
///
/// Each `path` follows `IgnoreProcessor`'s own trailing-slash directory-probe
/// convention: a path ending in `/` (e.g. `build/`) is evaluated as a
/// directory, passed straight through to `evaluate(_:isDirectory:)` with no
/// further interpretation by this command.
struct IgnoreCommand: AsyncParsableCommand {
  /// This subcommand's command-line configuration.
  static let configuration = CommandConfiguration(
    commandName: "ignore",
    abstract:
      "Evaluates paths against one or more combined ignore files. A trailing slash (e.g. 'build/') probes the path as a directory."
  )

  /// An ignore file to load; may be repeated. Files combine left-to-right
  /// with `+`, so a later `--file` overrides an earlier one.
  @Option(
    name: .customLong("file"),
    help: "An ignore file to load. May be repeated; later files override earlier ones.")
  var files: [String] = []

  /// The paths to evaluate. A trailing slash probes the path as a
  /// directory (git's `check-ignore` convention).
  @Argument(
    help: "Paths to evaluate. A trailing slash (e.g. 'build/') probes the path as a directory."
  )
  var paths: [String] = []

  /// Loads and combines every `--file` into one `IgnoreProcessor`, then
  /// prints one line per `path`: the path followed by its verdict's
  /// description (`ignored`/`included` and why).
  func run() throws {
    var processor = IgnoreProcessor(string: "", source: "<none>")
    for file in files {
      do {
        processor += try IgnoreProcessor(contentsOf: URL(fileURLWithPath: file))
      } catch {
        FileHandle.standardError.write(Data("ignore failed: \(error)\n".utf8))
        throw ExitCode.failure
      }
    }

    for path in paths {
      let verdict = processor.evaluate(path)
      print("\(path) \(verdict.description)")
    }
  }
}
