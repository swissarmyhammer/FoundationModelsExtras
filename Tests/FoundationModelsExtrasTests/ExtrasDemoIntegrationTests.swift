// `ExtrasDemoIntegrationTests` — the living contract test for
// `Examples/ExtrasDemo` (plan.md §7): launches the built `extras-demo`
// executable as a subprocess and asserts on its output streams and exit codes
// for every acceptance criterion on the `Examples/ExtrasDemo` kanban task.
//
// Deliberately a plain `import FoundationModelsExtras` with no `@testable`:
// the point of this suite is to prove the example's own construction path —
// a consumer with only the public surface — round-trips end to end.

import Foundation
import Synchronization
import Testing

@Suite struct ExtrasDemoIntegrationTests {

  // MARK: - Locating the built binary and fixtures

  /// The built `extras-demo` executable, located next to the running test bundle.
  ///
  /// SwiftPM places both under `.build/<config>/`. Declared as a dependency
  /// of the test target, so `swift test` builds it first.
  private static func extrasDemoBinary() throws -> URL {
    var candidates: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
      candidates.append(
        bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("extras-demo"))
    }
    let currentWorkingDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    candidates.append(currentWorkingDirectory.appendingPathComponent(".build/debug/extras-demo"))
    guard
      let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }
      )
    else {
      throw BinaryNotFoundError(candidates: candidates)
    }
    return binary
  }

  /// Raised by the subprocess harness itself when no built binary is found.
  private struct BinaryNotFoundError: Error, CustomStringConvertible {
    let candidates: [URL]
    var description: String { "extras-demo binary not found among: \(candidates.map(\.path))" }
  }

  /// The checked-in `Examples/ExtrasDemo/Fixtures/` tree.
  ///
  /// Resolved relative to the package root (this test file lives under
  /// `Tests/FoundationModelsExtrasTests/`, three levels below it).
  private static let fixturesRoot =
    PackageRootValidation.packageRoot()
    .appendingPathComponent("Examples/ExtrasDemo/Fixtures", isDirectory: true)

  // MARK: - Subprocess harness

  /// The result of running `extras-demo`: its two output streams, kept
  /// apart, and its exit code.
  private struct RunResult {
    /// Everything the run wrote to its standard output.
    let stdout: String
    /// Everything the run wrote to its standard error.
    let stderr: String
    /// The status the run exited with.
    let exitCode: Int32

    /// Both streams joined, standard output first — what a test that does
    /// not care which stream carried a line asserts against.
    var output: String { stdout + stderr }
  }

  /// The bytes one stream drain collects, behind a lock so the drain's own
  /// queue and the waiting caller never touch them at the same time.
  ///
  /// Lock-based rather than an `actor` for the same reason
  /// `FoundationModelsExtras.ProcessRegistry` is: every caller here is
  /// synchronous and cannot `await`. `readChunk(from:endingWith:)` runs
  /// inside a `readabilityHandler`, and `data` is read by `run(arguments:)`
  /// after a `DispatchGroup.wait()`. An `actor` would force both to `await`,
  /// and so would force `run(arguments:)` to become `async`.
  ///
  /// A `final class` around the `Mutex` because `Mutex` is non-copyable, so
  /// it cannot itself be captured by the escaping read handler.
  private final class StreamBuffer: Sendable {
    /// The bytes read so far.
    private let bytes = Mutex<Data>(Data())

    /// Reads one chunk from `handle`, and closes the drain out when that
    /// read signals end of file.
    ///
    /// An empty read is end of file. Clearing the handler there both stops
    /// the dispatch source and balances the `enter` that started the drain.
    ///
    /// - Parameters:
    ///   - handle: The read end being drained, as the handler supplies it.
    ///   - group: The group that tracks this drain to its end of file.
    func readChunk(from handle: FileHandle, endingWith group: DispatchGroup) {
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        group.leave()
        return
      }
      bytes.withLock { $0.append(chunk) }
    }

    /// A snapshot of the bytes collected so far.
    var data: Data {
      bytes.withLock { $0 }
    }
  }

  /// Starts draining `pipe` into `buffer`, and registers that drain with
  /// `group` so a caller can wait for its end of file.
  ///
  /// Reading through `readabilityHandler` puts the drain on Dispatch's own
  /// queue instead of the calling thread, which is what lets the two streams
  /// drain at the same time.
  ///
  /// - Parameters:
  ///   - pipe: The pipe whose read end gets drained.
  ///   - buffer: Where the bytes are collected.
  ///   - group: The group that tracks this drain to its end of file.
  private static func drain(
    _ pipe: Pipe, into buffer: StreamBuffer, notifying group: DispatchGroup
  ) {
    group.enter()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      buffer.readChunk(from: handle, endingWith: group)
    }
  }

  /// Launches the built `extras-demo` executable with `arguments`.
  ///
  /// Runs in a fresh temp working directory (so the run cannot depend on
  /// the process's cwd, and can never write into the repo), and collects
  /// each output stream and the exit code.
  ///
  /// **The two pipes must drain at the same time — do not make this
  /// sequential again.** A pipe holds about 64 KB before it blocks its
  /// writer. Reading standard output to its end first, and standard error
  /// only after that, deadlocks the moment the run writes more than that
  /// buffer to standard error: the child blocks on a full standard-error
  /// pipe and never closes standard output, so the read that is under way
  /// never reaches end of file and `waitUntilExit()` is never called. Both
  /// drains therefore start before the wait, each on its own Dispatch
  /// queue, and the wait is on the group that tracks both.
  private static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> RunResult {
    let workingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("extrasdemo-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workingDirectory) }

    let process = Process()
    process.executableURL = try extrasDemoBinary()
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = environment

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()

    let outputBuffer = StreamBuffer()
    let errorBuffer = StreamBuffer()
    let drained = DispatchGroup()
    drain(outputPipe, into: outputBuffer, notifying: drained)
    drain(errorPipe, into: errorBuffer, notifying: drained)
    drained.wait()
    process.waitUntilExit()

    return RunResult(
      stdout: String(decoding: outputBuffer.data, as: UTF8.self),
      stderr: String(decoding: errorBuffer.data, as: UTF8.self),
      exitCode: process.terminationStatus)
  }

  // MARK: - `stack`: source tracking and the EXTRASDEMO_DEFAULTS_DIR override

  @Test func stackReportsWhichLayerWonEachItem() throws {
    let result = try Self.run(arguments: ["stack"])

    #expect(result.exitCode == 0)
    #expect(result.output.contains("config.yaml -> project"))
    #expect(result.output.contains("hello -> defaults"))
    #expect(result.output.contains("status -> user"))
    #expect(result.output.contains("ps -> project"))
  }

  @Test func stackAnswersChangeWhenDefaultsDirectoryIsRepointedViaEnvVarWithNoRebuild() throws {
    var environment = ProcessInfo.processInfo.environment
    environment["EXTRASDEMO_DEFAULTS_DIR"] = Self.fixturesRoot.appendingPathComponent("user").path

    let result = try Self.run(arguments: ["stack"], environment: environment)

    #expect(result.exitCode == 0)
    // The user fixture (now standing in for defaults too) has no
    // "hello" command, so it disappears from the enumeration entirely —
    // the same binary, no rebuild, a different defaults directory.
    #expect(!result.output.contains("hello"))
    #expect(result.output.contains("ps -> project"))
  }

  // MARK: - `render`: context variable, env variable, well-known value, partial include

  @Test func renderShowsContextVariableEnvVariableWellKnownValueAndLayeredPartialInclude() throws {
    let goodFixture = Self.fixturesRoot.appendingPathComponent("render/good.md").path

    let result = try Self.run(arguments: ["render", goodFixture, "--set", "name=World"])

    #expect(result.exitCode == 0)
    #expect(result.output.contains("name=World"))
    #expect(result.output.contains("env_home="))
    #expect(result.output.contains("working_directory="))
    // The project fixture's `_partials/header.md` shadows the user
    // one — nearest-wins across the layered partials.
    #expect(result.output.contains("project header"))
  }

  // MARK: - `render --untrusted`: the trust split

  @Test func renderOfTheBadFixtureSucceedsTrustedButIsRejectedUntrusted() throws {
    let badFixture = Self.fixturesRoot.appendingPathComponent("render/bad.md").path

    let trusted = try Self.run(arguments: ["render", badFixture])
    #expect(trusted.exitCode == 0)

    let untrusted = try Self.run(arguments: ["render", badFixture, "--untrusted"])
    #expect(untrusted.exitCode != 0)
    #expect(untrusted.output.lowercased().contains("now"))
  }

  // MARK: - `commands`: prompt expansion, streamed action lines, commandUpdates

  @Test func commandsShowsPromptExpansionStreamedActionLinesAndTheUpdatedSet() throws {
    let result = try Self.run(arguments: ["commands"])

    #expect(result.exitCode == 0)
    #expect(result.output.contains("prompt 'greet' rendered: Hello World!"))
    #expect(result.output.contains("action 'stream' line: line 1 for demo-arg"))
    #expect(result.output.contains("action 'stream' line: line 2 for demo-arg"))
    #expect(result.output.contains("action 'stream' line: line 3 for demo-arg"))
    #expect(result.output.contains("commandUpdates republished: greet, stream, status"))
  }

  // MARK: - `agents`: AgentsMd walk over the nested fixture repo tree

  @Test func agentsWalksTheFixtureTreeReportingEachDirectorysGoverningAliasOutermostFirst() throws {
    let result = try Self.run(arguments: ["agents"])

    #expect(result.exitCode == 0)
    #expect(result.output.contains(". -> AGENTS.md"))
    #expect(result.output.contains("service -> AGENT.md"))
    // The leaf directory holds only the CLAUDE.md alias — no AGENTS.md or
    // AGENT.md beside it — proving alias-only directories are discovered
    // too, not just the canonical name.
    #expect(result.output.contains("service/api -> CLAUDE.md"))

    // Outermost-first ordering: the repo root's AGENTS.md line precedes the
    // alias-only leaf's CLAUDE.md line.
    let rootRange = try #require(result.output.range(of: ". -> AGENTS.md"))
    let leafRange = try #require(result.output.range(of: "service/api -> CLAUDE.md"))
    #expect(rootRange.lowerBound < leafRange.lowerBound)
  }

  // MARK: - `ignore`: IgnoreProcessor over the fixture tree, single-file, combined-file
  // override, trailing-slash directory probe, and the unreadable-file error case

  private static let gitignoreFixture = fixturesRoot.appendingPathComponent("ignore/.gitignore")
    .path
  private static let reviewIgnoreFixture = fixturesRoot.appendingPathComponent(
    "ignore/review-ignore"
  ).path

  @Test func ignoreReportsVerdictForASingleFile() throws {
    let result = try Self.run(arguments: ["ignore", "--file", Self.gitignoreFixture, "a.log"])

    #expect(result.exitCode == 0)
    #expect(result.output.contains("a.log ignored by \".gitignore\":1 `*.log`"))
  }

  @Test func ignoreCombinesTwoFilesWithTheLaterFileOverridingTheEarlier() throws {
    let result = try Self.run(arguments: [
      "ignore", "--file", Self.gitignoreFixture, "--file", Self.reviewIgnoreFixture, "src/keep.log",
    ])

    #expect(result.exitCode == 0)
    // `*.log` in .gitignore would ignore it, but review-ignore's
    // `!src/keep.log` is combined after it and wins under last-match-wins.
    #expect(result.output.contains("src/keep.log included by \"review-ignore\":1 `!src/keep.log`"))
  }

  @Test func ignoreHonorsTheTrailingSlashDirectoryProbe() throws {
    let result = try Self.run(arguments: ["ignore", "--file", Self.gitignoreFixture, "build/"])

    #expect(result.exitCode == 0)
    #expect(result.output.contains("build/ ignored by \".gitignore\":2 `build/`"))
  }

  @Test func ignoreExitsNonzeroNamingAnUnreadableIgnoreFile() throws {
    let missingFixture = Self.fixturesRoot.appendingPathComponent("ignore/does-not-exist").path

    let result = try Self.run(arguments: ["ignore", "--file", missingFixture, "a.log"])

    #expect(result.exitCode != 0)
    // The diagnostic belongs on standard error, and on standard error
    // alone — the stream a caller redirects away from the run's real
    // answer. Pinning it to the exact stream is what the two-pipe harness
    // makes possible.
    #expect(result.stderr.contains(missingFixture))
    #expect(!result.stdout.contains(missingFixture))
  }

  // MARK: - `config`: LayeredYAMLDocument merge across the fixture stack

  @Test func configPrintsTheMergedTreeAnnotatedWithWinningLayers() throws {
    let result = try Self.run(arguments: ["config"])

    #expect(result.exitCode == 0)
    // `source`, `profile`: scalars replaced wholesale, project wins (both
    // defaults and project define them, user doesn't touch `source` on its
    // own... project is present and highest-precedence for both).
    #expect(result.output.contains("source: project ← project"))
    #expect(result.output.contains("profile: pro ← project"))
    // `tags`: arrays replace wholesale — the user layer's single-element
    // array wins outright, never concatenated with the defaults layer's
    // `[alpha, beta]`.
    #expect(result.output.contains("tags: [gamma] ← user"))
    // `settings`: a dictionary section merged by key across all three
    // layers — `timeout` from project, `retries` from user.
    #expect(result.output.contains("settings.timeout: 60 ← project"))
    #expect(result.output.contains("settings.retries: 5 ← user"))
    // `token`: the user layer's value is templated (`{{ HOME }}`),
    // rendered per layer before parsing — proving the render-then-parse
    // rule runs per layer, not once over the merged tree.
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    #expect(result.output.contains("token: \(home) ← user"))
  }

  // MARK: - The harness keeps the two streams apart

  @Test func stackReportsOnStandardOutputWithNoPartOfItOnStandardError() throws {
    let result = try Self.run(arguments: ["stack"])

    #expect(result.exitCode == 0)
    #expect(!result.stdout.isEmpty)
    #expect(result.stdout.contains("config.yaml -> project"))

    // Every line of the report reaches standard output alone. None of them
    // also shows up on standard error — which is what a test asserting on
    // one exact stream depends on, and what the single-pipe harness could
    // never prove.
    for line in result.stdout.split(separator: "\n") {
      #expect(!result.stderr.contains(line))
    }
  }
}
