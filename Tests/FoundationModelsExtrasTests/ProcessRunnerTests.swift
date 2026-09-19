import FixtureSupport
import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavior tests for `ProcessRunner`: the exit code and the merged output,
/// the working directory, the timeout and the group kill, the output cap,
/// and the register/deregister ledger on `ProcessRegistry`.
///
/// Every test gives the runner its own **private** `ProcessRegistry()`, never
/// `ProcessRegistry.global`. swift-testing runs the suites of a package at
/// the same time in one process, and the global registry can hold pids that
/// belong to a different suite.
///
/// Each test is unit-fast: a child ends on its own in a fraction of a second,
/// or the runner kills it at a short timeout.
@Suite(.timeLimit(.minutes(1))) struct ProcessRunnerTests {

  /// A timeout that no test reaches: the child ends on its own first.
  private static let generousTimeout: Duration = .seconds(30)

  /// A timeout that a `sleep 60` child always passes.
  private static let shortTimeout: Duration = .milliseconds(500)

  /// The sleep that keeps a child alive until the runner kills it, in seconds.
  private static let longSleepSeconds = "60"

  /// The sleep the duration test measures, in seconds.
  private static let measuredSleepSeconds = 0.2

  /// A cap that no small test output reaches.
  private static let wideCap = ProcessRunner.OutputCap(lineCount: 64, byteLimit: 65_536)

  /// The count of lines `seq` writes in the output-cap tests.
  private static let manyLines = 100_000

  /// The pause between two reads of a registry, or of a pid, while a test
  /// waits for a state change.
  private static let pollInterval: Duration = .milliseconds(10)

  /// The count of polls a test makes before it gives up on a state change.
  private static let pollAttempts = 300

  /// Runs `/bin/sh -c script` through the runner with the given cap and
  /// registry, in a temporary directory.
  private static func runShell(
    _ script: String, timeout: Duration = generousTimeout, cap: ProcessRunner.OutputCap = wideCap,
    registry: ProcessRegistry = ProcessRegistry()
  ) async throws -> ProcessRunner.Outcome {
    try await ProcessRunner.run(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
      workingDirectory: FileManager.default.temporaryDirectory, timeout: timeout, outputCap: cap,
      registry: registry)
  }

  /// Runs `/bin/sleep 60` through the runner with the given timeout and
  /// registry.
  private static func runLongSleep(timeout: Duration, registry: ProcessRegistry) async throws
    -> ProcessRunner.Outcome
  {
    try await ProcessRunner.run(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [longSleepSeconds],
      workingDirectory: FileManager.default.temporaryDirectory, timeout: timeout,
      outputCap: wideCap, registry: registry)
  }

  /// Polls `registry` until it holds one pid, and gives that pid, or `nil`
  /// when the poll budget runs out first.
  private static func registeredPid(in registry: ProcessRegistry) async throws -> pid_t? {
    for _ in 0..<pollAttempts {
      if let pid = registry.registeredPids.first {
        return pid
      }
      try await Task.sleep(for: pollInterval)
    }
    return nil
  }

  /// Polls until `pid` is gone, and tells whether it went away inside the poll
  /// budget. A pid is gone when `kill(pid, 0)` fails with `ESRCH`.
  private static func isGone(_ pid: pid_t) async throws -> Bool {
    for _ in 0..<pollAttempts {
      if kill(pid, 0) == -1 && errno == ESRCH {
        return true
      }
      try await Task.sleep(for: pollInterval)
    }
    return false
  }

  // MARK: - A command that ends on its own

  @Test func aCommandThatEndsGivesItsExitCodeAndItsMergedOutput() async throws {
    let exitCode: Int32 = 3

    let outcome = try await Self.runShell("echo one; echo two >&2; echo three; exit \(exitCode)")

    #expect(outcome.termination == .exited(code: exitCode))
    #expect(outcome.output == ["one", "two", "three"])
    #expect(outcome.lineCount == outcome.output.count)
    #expect(!outcome.isTruncated)
  }

  @Test func aCommandRunsInTheGivenWorkingDirectory() async throws {
    let uncanonicalDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: uncanonicalDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: uncanonicalDirectory) }
    // `pwd` prints the real path, so the expected path must cross the
    // `/var` firmlink too. `realpath(3)` needs the directory to exist first.
    let directory = uncanonicalDirectory.canonicalDirectory

    let outcome = try await ProcessRunner.run(
      executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], workingDirectory: directory,
      timeout: Self.generousTimeout, outputCap: Self.wideCap, registry: ProcessRegistry())

    #expect(outcome.output == [directory.path])
  }

  @Test func theDurationCoversTheWholeRun() async throws {
    let outcome = try await Self.runShell("sleep \(Self.measuredSleepSeconds)")

    #expect(outcome.termination == .exited(code: 0))
    #expect(outcome.duration >= .seconds(Self.measuredSleepSeconds))
  }

  // MARK: - The timeout, and the group kill

  @Test func aCommandThatPassesTheTimeoutGivesTheTimeoutResultAndTheGroupIsGone() async throws {
    let registry = ProcessRegistry()
    async let run = Self.runLongSleep(timeout: Self.shortTimeout, registry: registry)
    let pid = try #require(try await Self.registeredPid(in: registry))

    let outcome = try await run

    #expect(outcome.termination == .timedOut)
    #expect(registry.registeredPids.isEmpty)
    #expect(try await Self.isGone(pid))
  }

  @Test func aChildOfTheChildIsAlsoKilledBecauseTheKillGoesToTheGroup() async throws {
    let outcome = try await Self.runShell(
      "sleep \(Self.longSleepSeconds) & echo $!; wait", timeout: Self.shortTimeout)

    #expect(outcome.termination == .timedOut)
    let grandchildText = try #require(outcome.output.first)
    let grandchild = try #require(pid_t(grandchildText))
    #expect(try await Self.isGone(grandchild))
  }

  // MARK: - The registry ledger

  @Test func theRegistryHoldsThePidWhileTheProcessRunsAndNothingAfterTheCall() async throws {
    let registry = ProcessRegistry()
    async let run = Self.runLongSleep(timeout: Self.generousTimeout, registry: registry)
    let pid = try #require(try await Self.registeredPid(in: registry))

    #expect(kill(pid, 0) == 0)
    #expect(killpg(pid, SIGKILL) == 0)
    let outcome = try await run

    #expect(outcome.termination == .signaled(SIGKILL))
    #expect(registry.registeredPids.isEmpty)
  }

  @Test func aSpawnFailureThrowsAndLeavesTheRegistryEmpty() async throws {
    let registry = ProcessRegistry()
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("no-such-executable")

    await #expect(throws: ProcessRunner.Failure.spawnFailed(status: ENOENT)) {
      try await ProcessRunner.run(
        executable: missing, arguments: [],
        workingDirectory: FileManager.default.temporaryDirectory, timeout: Self.generousTimeout,
        outputCap: Self.wideCap, registry: registry)
    }
    #expect(registry.registeredPids.isEmpty)
  }

  // MARK: - The wait status

  @Test func aWaitStatusDecodesToTheExitCodeOrToTheSignal() {
    let exitCode: Int32 = 3
    let exitStatus = exitCode << 8

    #expect(ProcessRunner.Termination(waitStatus: exitStatus) == .exited(code: exitCode))
    #expect(ProcessRunner.Termination(waitStatus: SIGKILL) == .signaled(SIGKILL))
  }

  // MARK: - The output cap

  @Test func aCommandThatWritesMoreLinesThanTheLineCapGivesTheTailWithTheMark() async throws {
    let lineCap = 3
    let cap = ProcessRunner.OutputCap(lineCount: lineCap, byteLimit: Self.wideCap.byteLimit)

    let outcome = try await Self.runShell("seq 1 \(Self.manyLines)", cap: cap)

    #expect(outcome.termination == .exited(code: 0))
    #expect(outcome.lineCount == Self.manyLines)
    #expect(outcome.output == ["99998", "99999", "100000"])
    #expect(outcome.isTruncated)
  }

  @Test func aCommandThatWritesMoreBytesThanTheByteLimitGivesTheTailWithTheMark() async throws {
    let byteLimit = 64
    let cap = ProcessRunner.OutputCap(lineCount: Self.manyLines, byteLimit: byteLimit)

    let outcome = try await Self.runShell("seq 1 \(Self.manyLines)", cap: cap)

    #expect(outcome.lineCount == Self.manyLines)
    #expect(outcome.output.last == "100000")
    #expect(outcome.output.count < Self.manyLines)
    #expect(outcome.output.reduce(0) { $0 + $1.utf8.count } <= byteLimit)
    #expect(outcome.isTruncated)
  }

  // MARK: - The accumulator never holds more than the byte limit

  @Test func theTailNeverHoldsMoreThanTheByteLimitWhileTheReadRuns() {
    let lineCap = 8
    let byteLimit = 512
    let lineLength = 4096
    let lineCount = 64
    var tail = ProcessOutputTail(
      cap: ProcessRunner.OutputCap(lineCount: lineCap, byteLimit: byteLimit))
    let chunk = Data(repeating: UInt8(ascii: "x"), count: lineLength) + Data("\n".utf8)

    for _ in 0..<lineCount {
      tail.append(chunk)
      #expect(tail.retainedByteCount <= byteLimit)
    }

    let outcome = tail.finish()
    #expect(outcome.lineCount == lineCount)
    #expect(outcome.isTruncated)
  }

  @Test func aLineWithNoNewlineIsCutToTheByteLimitWhileTheReadRuns() {
    let byteLimit = 16
    let chunkCount = 10
    var tail = ProcessOutputTail(
      cap: ProcessRunner.OutputCap(lineCount: Self.wideCap.lineCount, byteLimit: byteLimit))
    let chunk = Data("abcdefghij".utf8)

    for _ in 0..<chunkCount {
      tail.append(chunk)
      #expect(tail.retainedByteCount <= byteLimit)
    }

    let outcome = tail.finish()
    #expect(outcome.lineCount == 1)
    #expect(outcome.output == ["efghijabcdefghij"])
    #expect(outcome.isTruncated)
  }

  @Test func aTrailingNewlineAddsNoEmptyLineAndAPartialLastLineCounts() {
    var withTrailingNewline = ProcessOutputTail(cap: Self.wideCap)
    withTrailingNewline.append(Data("a\nb\n".utf8))
    var withPartialLine = ProcessOutputTail(cap: Self.wideCap)
    withPartialLine.append(Data("a\nb".utf8))

    #expect(withTrailingNewline.finish().output == ["a", "b"])
    #expect(withPartialLine.finish().output == ["a", "b"])
  }

  @Test func aLineSplitAcrossTwoChunksIsOneLine() {
    var tail = ProcessOutputTail(cap: Self.wideCap)
    tail.append(Data("hel".utf8))
    tail.append(Data("lo\nwor".utf8))
    tail.append(Data("ld\n".utf8))

    let outcome = tail.finish()
    #expect(outcome.output == ["hello", "world"])
    #expect(outcome.lineCount == 2)
    #expect(!outcome.isTruncated)
  }

  // MARK: - README example

  /// Mirrored in the `ProcessRunner` section of README.md. Keep the two in
  /// sync.
  ///
  /// Makes the one call the README shows, with the README's script, and
  /// checks the exit code, the merged output, and the mark, so the README
  /// cannot go stale without a test that fails. The README leaves `registry`
  /// at its default, `ProcessRegistry.global`. This test gives a private
  /// registry, for the reason the suite documentation states.
  @Test func readmeExitCodeAndMergedOutputExample() async throws {
    let exitCode: Int32 = 2

    let outcome = try await ProcessRunner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo building; echo warning: slow >&2; exit \(exitCode)"],
      workingDirectory: FileManager.default.temporaryDirectory,
      timeout: Self.generousTimeout,
      outputCap: Self.wideCap,
      registry: ProcessRegistry())

    #expect(outcome.termination == .exited(code: exitCode))
    #expect(outcome.output == ["building", "warning: slow"])
    #expect(!outcome.isTruncated)
  }
}
