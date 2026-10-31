import FixtureSupport
import Foundation
import Synchronization
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
/// or the runner kills it when a stand-in timer fires (``StandInTimer``).
/// No test sleeps or polls. A test that needs the pid of a running child
/// gets it from the child through a named pipe (``PidHandshake``). The wait
/// for the exit of a grandchild has no deadline: the grandchild ends at the
/// group kill, or by itself after its sleep, and only the second end writes a
/// marker file (``exits(_:)``).
///
/// A timeout test fires its timer only after the child gave its pid. When
/// the timer or the kill is wrong, the only other end of the run is the end
/// of the child sleep. The start of the timer and the pid handshake have no
/// fixed order, thus no earlier event can show that the timer is wrong.
@Suite struct ProcessRunnerTests {

  /// A timeout that no test reaches: the child ends on its own first.
  private static let generousTimeout: Duration = .seconds(30)

  /// The sleep that keeps a child alive until the runner kills it, in seconds.
  private static let longSleepSeconds = "60"

  /// The sleep the duration test measures, in seconds.
  private static let measuredSleepSeconds = 0.2

  /// A cap that no small test output reaches.
  private static let wideCap = ProcessRunner.OutputCap(lineCount: 64, byteLimit: 65_536)

  /// The count of lines `seq` writes in the output-cap tests.
  private static let manyLines = 100_000

  /// The bytes that the handshake child writes before it gives its pid. The
  /// count is larger than the buffer of a pipe, thus the write ends only
  /// after the runner reads the pipe. The runner starts to read only after
  /// it registered the pid, thus the pid is in the registry when the test
  /// gets it.
  private static let pipeFillBytes = 262_144

  /// Runs `/bin/sh -c script` through the runner with the given cap,
  /// registry and control, in a temporary directory.
  private static func runShell(
    _ script: String, timeout: Duration = generousTimeout, cap: ProcessRunner.OutputCap = wideCap,
    registry: ProcessRegistry = ProcessRegistry(), control: ProcessRunner.ChildControl = .system
  ) async throws -> ProcessRunner.Outcome {
    try await ProcessRunner.run(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
      workingDirectory: FileManager.default.temporaryDirectory, timeout: timeout, outputCap: cap,
      registry: registry, control: control)
  }

  /// A timer of the timeout that fires only when the test fires it. It
  /// stands in for the real sleep of `ChildControl.system`, and each other
  /// step of the runner stays real.
  private struct StandInTimer {
    /// Opens when the test fires the timer.
    private let fired = RunLatch()

    /// `ChildControl.system` with this timer in place of the real sleep.
    /// The timer also ends at a cancel of its task, as the real sleep does,
    /// so the runner does not wait for it after the reap.
    var control: ProcessRunner.ChildControl {
      var control = ProcessRunner.ChildControl.system
      let fired = fired
      control.sleep = { _ in
        await withTaskCancellationHandler {
          await fired.waitUntilOpen()
        } onCancel: {
          fired.open()
        }
      }
      return control
    }

    /// Fires the timer. A second fire does nothing.
    func fire() {
      fired.open()
    }
  }

  /// Runs `/bin/sh -c` with the script that `makeScript` makes, on a
  /// stand-in timer, and fires the timer when the child gave its pid.
  ///
  /// The script must write the pid of the shell to the handshake while the
  /// shell still runs. On each throw, the timer fires, and the call waits
  /// for the run: the runner then kills the group and reaps the child, so
  /// no child and no wait stay.
  ///
  /// - Parameters:
  ///   - registry: The registry of the run.
  ///   - makeScript: Makes the script from the handshake.
  /// - Returns: The pid of the shell, and the outcome of the run.
  /// - Throws: When the child gave no pid, or the error of the run.
  private static func runShellPastItsTimer(
    registry: ProcessRegistry = ProcessRegistry(), _ makeScript: (PidHandshake) -> String
  ) async throws -> (pid: pid_t, outcome: ProcessRunner.Outcome) {
    let handshake = try PidHandshake()
    defer { handshake.remove() }
    let timer = StandInTimer()
    let script = makeScript(handshake)
    let control = timer.control
    let run = Task { try await runShell(script, registry: registry, control: control) }
    do {
      let pid = try #require(await handshake.pid(orUntilEndOf: run), "the child gave no pid")
      timer.fire()
      return (pid, try await run.value)
    } catch {
      timer.fire()
      _ = await run.result
      throw error
    }
  }

  /// Tells whether `pid` is gone now: `kill(pid, 0)` fails with `ESRCH`.
  ///
  /// - Parameter pid: The pid.
  /// - Returns: `true` when no process has the pid.
  private static func isGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
  }

  /// A named pipe in a new temporary folder. A child writes its pid to it,
  /// and the test reads the pid, with no poll.
  private struct PidHandshake {
    /// The named pipe.
    let url: URL

    /// Makes the folder and the named pipe.
    ///
    /// - Throws: When the folder or the pipe cannot be made.
    init() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      url = directory.appendingPathComponent("pid")
      try #require(mkfifo(url.path, S_IRUSR | S_IWUSR) == 0, "mkfifo failed with errno \(errno)")
    }

    /// The shell line that writes the pid of the shell to the pipe.
    var writeShellPid: String {
      "echo $$ > '\(url.path)'"
    }

    /// Reads the pid from the pipe, or ends with `nil` when `run` ends first.
    ///
    /// The open of a named pipe blocks until the other end opens, thus the
    /// read runs on a thread of its own. When `run` ends first, this function
    /// opens the write end, so the read ends and the thread does not stay.
    ///
    /// - Parameter run: The task of the call that starts the child.
    /// - Returns: The pid, or `nil` when no pid came.
    func pid<Value: Sendable>(orUntilEndOf run: Task<Value, any Error>) async -> pid_t? {
      let read = Promise<pid_t?>()
      let path = url.path
      Thread {
        let data = FileHandle(forReadingAtPath: path)?.readDataToEndOfFile() ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        read.fulfill(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
      }.start()
      await Waits.untilFirstEnds({ _ = await read.value }, { _ = await run.result })
      if read.fulfilledValue == nil {
        Thread { _ = close(open(path, O_WRONLY)) }.start()
      }
      return read.fulfilledValue ?? nil
    }

    /// Removes the folder of the pipe.
    func remove() {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
  }

  /// Waits until `pid` exits.
  ///
  /// The group kill stops a grandchild, and launchd then owns the
  /// grandchild. Only the OS reports its exit, as a `NOTE_EXIT` event of a
  /// kqueue. The wait has no deadline: a grandchild that the kill did not
  /// reach ends by itself at the end of its sleep. The wait runs on a thread
  /// of its own, because `kevent` blocks.
  ///
  /// - Parameter pid: The pid of the process.
  /// - Returns: `true` when the process exited, or was gone already.
  private static func exits(_ pid: pid_t) async -> Bool {
    await withCheckedContinuation { continuation in
      Thread { continuation.resume(returning: waitForExit(of: pid)) }.start()
    }
  }

  /// Blocks in `kevent` until `pid` exits.
  ///
  /// - Parameter pid: The pid of the process.
  /// - Returns: `true` when the process exited, or was gone already.
  private static func waitForExit(of pid: pid_t) -> Bool {
    let queue = kqueue()
    guard queue >= 0 else { return false }
    defer { close(queue) }
    var change = kevent(
      ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT,
      data: 0, udata: nil)
    var event = kevent()
    let count = kevent(queue, &change, 1, &event, 1, nil)
    if count < 0 {
      return errno == ESRCH
    }
    guard count == 1 else { return false }
    // A registration error comes back as an event with `EV_ERROR`. A
    // process that is already gone gives `ESRCH`.
    return event.flags & UInt16(EV_ERROR) == 0 || event.data == Int(ESRCH)
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

    // The shell gives its pid, then becomes the long sleep with the same pid.
    let (pid, outcome) = try await Self.runShellPastItsTimer(registry: registry) { handshake in
      "\(handshake.writeShellPid); exec sleep \(Self.longSleepSeconds)"
    }

    #expect(outcome.termination == .timedOut, "the child ended with \(outcome.termination), not at the timeout")
    #expect(registry.registeredPids.isEmpty)
    // The runner reaped the child before it returned, thus the pid is gone
    // now, with no wait.
    #expect(Self.isGone(pid))
  }

  @Test func aChildOfTheChildIsAlsoKilledBecauseTheKillGoesToTheGroup() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    // The grandchild writes the marker only when its sleep ends by itself.
    // The shell gives its pid only after it started the grandchild.
    let (_, outcome) = try await Self.runShellPastItsTimer { handshake in
      "(sleep \(Self.longSleepSeconds); touch '\(marker.path)') & echo $!; \(handshake.writeShellPid); wait"
    }

    #expect(outcome.termination == .timedOut, "the child ended with \(outcome.termination), not at the timeout")
    let grandchildText = try #require(outcome.output.first)
    let grandchild = try #require(pid_t(grandchildText))
    #expect(await Self.exits(grandchild))
    // A grandchild that the group kill did not reach ends after its sleep,
    // and then the marker is there.
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  // MARK: - No kill after the reap

  /// A pid that the stand-in steps of `raceTheTimerAfterTheReap(kills:)`
  /// use. No real process gets a signal, because a recorder stands in for
  /// the kill.
  private static let standInPid: pid_t = 4242

  /// Runs `ProcessRunner.waitOrKill` with stand-in steps in a fixed order:
  /// the child ends, the reap path closes the right to kill and starts the
  /// reap, and only then does the timer fire. The reap does not return
  /// until the timer is at its kill, so the kill of the timer comes after
  /// the reap in each run.
  ///
  /// After the reap, the kernel can give the pid to an unrelated process,
  /// so a kill at that time can reach a process that is not ours.
  ///
  /// - Parameter kills: The recorder that stands in for the kill.
  /// - Returns: How `waitOrKill` says the child ended.
  private static func raceTheTimerAfterTheReap(kills: KillRecorder) async throws
    -> ProcessRunner.Termination
  {
    let (reaped, reapedContinuation) = AsyncStream<Void>.makeStream()
    let (timerAtKill, timerAtKillContinuation) = AsyncStream<Void>.makeStream()
    let control = ProcessRunner.ChildControl(
      awaitExit: { _ in },
      reap: { _ in
        reapedContinuation.finish()
        for await _ in timerAtKill {}
        return .exited(code: 0)
      },
      sleep: { _ in
        for await _ in reaped {}
      },
      signalGroup: { pid in kills.record(pid) },
      timerWillSignal: { timerAtKillContinuation.finish() })

    return try await ProcessRunner.waitOrKill(
      pid: Self.standInPid, timeout: Self.generousTimeout, control: control)
  }

  @Test func aTimerThatFiresAfterTheReapStartedSendsNoKill() async throws {
    let kills = KillRecorder()

    _ = try await Self.raceTheTimerAfterTheReap(kills: kills)

    #expect(
      kills.pids.isEmpty,
      "the timer sent a kill to \(kills.pids) after the reap of the child started")
  }

  @Test func aTimerThatFiresAfterTheReapStartedGivesTheTerminationOfTheReap() async throws {
    let termination = try await Self.raceTheTimerAfterTheReap(kills: KillRecorder())

    #expect(termination == .exited(code: 0))
  }

  // MARK: - The registry ledger

  @Test func theRegistryHoldsThePidWhileTheProcessRunsAndNothingAfterTheCall() async throws {
    let registry = ProcessRegistry()
    let handshake = try PidHandshake()
    defer { handshake.remove() }
    // The fill of the pipe ends only after the runner reads it, and the
    // runner reads only after it registered the pid.
    let script =
      "head -c \(Self.pipeFillBytes) /dev/zero; \(handshake.writeShellPid); exec sleep \(Self.longSleepSeconds)"
    let run = Task { try await Self.runShell(script, registry: registry) }
    let pid = try #require(await handshake.pid(orUntilEndOf: run))

    #expect(registry.registeredPids == [pid])
    #expect(kill(pid, 0) == 0)
    #expect(killpg(pid, SIGKILL) == 0)
    let outcome = try await run.value

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

  /// Mirrored in the `ProcessRunner` section of docs/REFERENCE.md. Keep the two in
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

/// Records each kill of a process group that a runner sends, in place of
/// `killpg`. No kill reaches a real process.
private final class KillRecorder: Sendable {
  /// The pid of each recorded kill, in the order of the calls.
  private let recorded = Mutex<[pid_t]>([])

  /// Records one kill of the group that `pid` leads.
  ///
  /// - Parameter pid: The pid that the kill names.
  func record(_ pid: pid_t) {
    recorded.withLock { $0.append(pid) }
  }

  /// The pid of each recorded kill, in the order of the calls.
  var pids: [pid_t] {
    recorded.withLock { $0 }
  }
}
