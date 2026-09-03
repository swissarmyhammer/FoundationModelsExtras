import FixtureSupport
import Foundation

/// One finished subprocess: what it wrote, and how it exited.
struct ProcessOutcome {
  /// Everything the process wrote to standard output, decoded as UTF-8.
  let standardOutput: String
  /// Everything the process wrote to standard error, decoded as UTF-8.
  let standardError: String
  /// The process's exit status.
  let terminationStatus: Int32
}

/// Runs the child processes the recorder needs.
enum Subprocess {
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
  /// - Throws: `FixtureError` if the process cannot be launched, or if its
  ///   standard-error capture file cannot be created or reopened.
  static func run(
    arguments: [String],
    currentDirectory: URL,
    standardInputFile: URL? = nil,
    scratchDirectory: URL
  ) throws -> ProcessOutcome {
    let errorFileURL = scratchDirectory.appendingPathComponent("stderr-\(UUID().uuidString).txt")
    guard FileManager.default.createFile(atPath: errorFileURL.path, contents: nil) else {
      throw FixtureError(message: "could not create \(errorFileURL.path)")
    }
    guard let errorHandle = FileHandle(forWritingAtPath: errorFileURL.path) else {
      throw FixtureError(message: "could not open \(errorFileURL.path) for writing")
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
        throw FixtureError(message: "could not open \(standardInputFile.path) for reading")
      }
      process.standardInput = inputHandle
    }

    do {
      try process.run()
    } catch {
      throw FixtureError(
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
  /// - Throws: `FixtureError` if the process cannot be launched or exits
  ///   non-zero.
  static func runExpectingSuccess(
    arguments: [String], currentDirectory: URL, scratchDirectory: URL
  ) throws {
    let outcome = try run(
      arguments: arguments, currentDirectory: currentDirectory,
      scratchDirectory: scratchDirectory)
    guard outcome.terminationStatus == EXIT_SUCCESS else {
      throw FixtureError(
        message: """
          \(arguments.joined(separator: " ")) exited \(outcome.terminationStatus): \
          \(outcome.standardError)
          """)
    }
  }
}
