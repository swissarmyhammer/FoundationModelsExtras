import Darwin
import Foundation

/// Runs one executable directly (no shell) in its own process group, with
/// stdout and stderr merged into one bounded tail, a timeout that kills the
/// whole group with `SIGKILL`, and a pid that stands in a `ProcessRegistry`
/// for the full life of the child.
///
/// The runner spawns with `posix_spawn` and not with `Foundation.Process`.
/// `Process` gives no way to put the child, and each grandchild the child
/// forks before its exec completes, into a new process group at the moment
/// of the spawn. Only `POSIX_SPAWN_SETPGROUP`, applied as part of the spawn
/// call, closes that race. Without it, a child that puts its own child in
/// the background (`sleep 100 &`) could keep that grandchild alive after a
/// timeout kills only the direct child.
///
/// The child inherits the environment and the stdin of the caller.
public enum ProcessRunner {
  /// The limits on the output a run keeps.
  public struct OutputCap: Equatable, Sendable {
    /// The count of complete lines the run keeps: the tail of the output.
    public let lineCount: Int

    /// The most bytes the run holds at one time, the line in progress
    /// included. A read that passes this limit drops the oldest bytes at
    /// once, so a process that writes without end cannot grow the memory of
    /// the caller.
    public let byteLimit: Int

    /// Creates a cap.
    ///
    /// - Parameters:
    ///   - lineCount: The count of complete lines to keep.
    ///   - byteLimit: The most bytes to hold at one time.
    public init(lineCount: Int, byteLimit: Int) {
      self.lineCount = lineCount
      self.byteLimit = byteLimit
    }
  }

  /// How a run ended.
  public enum Termination: Equatable, Sendable {
    /// The process ended on its own, before the timeout, with this exit
    /// code.
    case exited(code: Int32)

    /// The process ended on its own, before the timeout, because of this
    /// signal.
    case signaled(Int32)

    /// The timeout passed, and the runner sent `SIGKILL` to the whole
    /// process group.
    case timedOut
  }

  /// The result of one run.
  public struct Outcome: Equatable, Sendable {
    /// How the run ended.
    public let termination: Termination

    /// The wall-clock time from the spawn to the reap.
    public let duration: Duration

    /// The count of all the lines the process wrote to stdout and stderr,
    /// the dropped lines included.
    public let lineCount: Int

    /// The kept tail of the merged output, in arrival order.
    public let output: [String]

    /// `true` when the cap cut the output, so `output` holds less than the
    /// process wrote.
    public let isTruncated: Bool
  }

  /// A failure of the run itself, before or after the child ran.
  public enum Failure: Error, Equatable {
    /// `posix_spawn` did not reach exec. The status is the `errno` value it
    /// gave, for example `ENOENT` when the executable is not there.
    case spawnFailed(status: Int32)

    /// `waitid` could not wait for the child, or `waitpid` could not reap
    /// it. This happens only when the host process ignores `SIGCHLD`, so
    /// the kernel reaps each child on its own.
    case waitFailed(errno: Int32)
  }

  /// Runs `executable` directly, in its own process group.
  ///
  /// The pid stands in `registry` from the spawn to the return, so a sweep
  /// of the registry at a normal exit of the host kills the group when this
  /// call never returned. The runner deregisters the pid after the group
  /// kill and the reap, on every path: a normal end, a timeout, and a
  /// failed reap.
  ///
  /// A cancel of the calling task acts as a timeout: the group dies at once,
  /// and the outcome reads `.timedOut`.
  ///
  /// - Parameters:
  ///   - executable: The file to exec.
  ///   - arguments: The positional arguments after the executable path.
  ///   - workingDirectory: The working directory of the child.
  ///   - timeout: How long the child can run before the group kill.
  ///   - outputCap: The count of lines and the byte limit of the kept output.
  ///   - registry: The registry that holds the pid while the child runs.
  /// - Returns: How the run ended, how long it took, and the kept output.
  /// - Throws: `Failure.spawnFailed` when the spawn did not reach exec, and
  ///   `Failure.waitFailed` when the reap failed.
  public static func run(
    executable: URL, arguments: [String], workingDirectory: URL, timeout: Duration,
    outputCap: OutputCap, registry: ProcessRegistry = .global
  ) async throws -> Outcome {
    try await run(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      timeout: timeout, outputCap: outputCap, registry: registry, control: .system)
  }

  /// Runs `executable` directly, in its own process group, and waits for,
  /// reaps and kills the child through `control`.
  ///
  /// The public `run` gives ``ChildControl/system``. A test gives a copy of
  /// it with a stand-in timer, so the timeout fires at a point that the test
  /// chooses, and the spawn, the wait, the reap and the kill stay real.
  ///
  /// - Parameters:
  ///   - executable: The file to exec.
  ///   - arguments: The positional arguments after the executable path.
  ///   - workingDirectory: The working directory of the child.
  ///   - timeout: How long the child can run before the group kill.
  ///   - outputCap: The count of lines and the byte limit of the kept output.
  ///   - registry: The registry that holds the pid while the child runs.
  ///   - control: The steps that wait for, reap, and kill the child.
  /// - Returns: How the run ended, how long it took, and the kept output.
  /// - Throws: `Failure.spawnFailed` when the spawn did not reach exec, and
  ///   `Failure.waitFailed` when the reap failed.
  static func run(
    executable: URL, arguments: [String], workingDirectory: URL, timeout: Duration,
    outputCap: OutputCap, registry: ProcessRegistry, control: ChildControl
  ) async throws -> Outcome {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    let pid: pid_t
    do {
      // The copy of the write end that the parent holds must close, so EOF
      // shows on the read end when each process that holds a dup of it (the
      // child, and each grandchild) has ended.
      defer { try? pipe.fileHandleForWriting.close() }
      pid = try Self.spawn(
        executable: executable, arguments: arguments, workingDirectory: workingDirectory,
        writeDescriptor: pipe.fileHandleForWriting.fileDescriptor)
    }
    registry.register(pid)
    defer { registry.deregister(pid) }

    let start = ContinuousClock.now
    async let capture = Self.readToEnd(
      descriptor: pipe.fileHandleForReading.fileDescriptor, cap: outputCap)
    let termination = try await Self.waitOrKill(pid: pid, timeout: timeout, control: control)
    let captured = try await capture
    return Outcome(
      termination: termination, duration: start.duration(to: .now), lineCount: captured.lineCount,
      output: captured.output, isTruncated: captured.isTruncated)
  }

  // MARK: - Spawn

  /// Spawns `executable` with `posix_spawn`, in its own process group, with
  /// `writeDescriptor` dup'd to both stdout and stderr.
  ///
  /// - Parameters:
  ///   - executable: The file to exec.
  ///   - arguments: The positional arguments after the executable path.
  ///   - workingDirectory: The working directory of the child.
  ///   - writeDescriptor: The write end of the pipe, to dup to stdout and
  ///     stderr.
  /// - Returns: The pid of the child, which is also its process-group id.
  /// - Throws: `Failure.spawnFailed` with the status `posix_spawn` gave.
  private static func spawn(
    executable: URL, arguments: [String], workingDirectory: URL, writeDescriptor: Int32
  ) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, writeDescriptor)
    posix_spawn_file_actions_addchdir(&fileActions, workingDirectory.path)

    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)

    let path = executable.path
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)] + arguments.map { strdup($0) } + [nil]
    defer { for case let argument? in argv { free(argument) } }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, path, &fileActions, &attributes, argv, environ)
    guard status == 0 else { throw Failure.spawnFailed(status: status) }
    return pid
  }

  // MARK: - Wait, or kill at the timeout

  /// One result of the race between the reap and the timeout.
  private enum Race: Sendable {
    /// The reap won: the child ended on its own.
    case reaped(Termination)

    /// The timeout won.
    case timedOut
  }

  /// The steps that wait for, reap, and kill one child, and the timer of the
  /// timeout.
  ///
  /// ``system`` holds the real system calls. A test gives stand-ins, so it
  /// can put the reap and the timer in a fixed order, and so no signal
  /// reaches a real process.
  struct ChildControl: Sendable {
    /// Blocks until the child ended, and leaves it unreaped. The pid of the
    /// child stays reserved until ``reap`` runs.
    var awaitExit: @Sendable (pid_t) async throws -> Void

    /// Reaps the child that ``awaitExit`` saw end, and gives how it ended.
    var reap: @Sendable (pid_t) async throws -> Termination

    /// Returns when the timeout passed, or when the task is cancelled.
    var sleep: @Sendable (Duration) async -> Void

    /// Sends `SIGKILL` to the process group that the pid leads.
    var signalGroup: @Sendable (pid_t) -> Void

    /// Runs after the timer fired and before its kill. It does nothing in
    /// ``system``. A test holds the kill here until the reap path moved on.
    var timerWillSignal: @Sendable () async -> Void

    /// The real system calls.
    static let system = ChildControl(
      awaitExit: { pid in try await ProcessRunner.awaitExit(pid) },
      reap: { pid in try await ProcessRunner.reap(pid) },
      sleep: { timeout in try? await Task.sleep(for: timeout) },
      signalGroup: { pid in _ = killpg(pid, SIGKILL) },
      timerWillSignal: {})
  }

  /// Races the end of `pid` against `timeout`. When the timeout wins, sends
  /// `SIGKILL` to the whole process group of `pid`, then reaps it.
  ///
  /// The kill goes through a ``ProcessGroupKill``. The reap path closes it
  /// after the child ended and before the reap, so no kill reaches the pid
  /// after the reap, when the kernel can give that pid to an unrelated
  /// process. A timer that fires after the close sends nothing, and the
  /// result is how the child ended on its own.
  ///
  /// - Parameters:
  ///   - pid: The child, which leads its own process group.
  ///   - timeout: How long to wait before the group kill.
  ///   - control: The steps that wait for, reap, and kill the child.
  /// - Returns: How the child ended, or `.timedOut` when the kill went out.
  /// - Throws: `Failure.waitFailed` when the wait or the reap failed.
  static func waitOrKill(
    pid: pid_t, timeout: Duration, control: ChildControl = .system
  ) async throws -> Termination {
    let processGroup = ProcessGroupKill(pid: pid, signal: control.signalGroup)
    return try await withThrowingTaskGroup(of: Race.self) { group in
      group.addTask {
        try await control.awaitExit(pid)
        processGroup.close()
        return .reaped(try await control.reap(pid))
      }
      group.addTask {
        await control.sleep(timeout)
        return .timedOut
      }

      var timedOut = false
      while let race = try await group.next() {
        switch race {
        case .reaped(let termination):
          group.cancelAll()
          return timedOut ? .timedOut : termination
        case .timedOut:
          // The reap task ends once the group is dead; the next iteration
          // takes its result, so no second `waitpid` runs for the same pid.
          await control.timerWillSignal()
          timedOut = processGroup.kill()
        }
      }
      // The reap task always gives a result or throws, so the loop returns
      // before the group runs dry. The compiler still needs an exit here.
      return .timedOut
    }
  }

  /// Blocks (on a background thread) until `pid` ends, and leaves it
  /// unreaped, so the kernel keeps its pid.
  ///
  /// - Parameter pid: The child to wait for.
  /// - Throws: `Failure.waitFailed` when `waitid` failed for a cause other
  ///   than an interrupt.
  private static func awaitExit(_ pid: pid_t) async throws {
    try await Self.blocking {
      var info = siginfo_t()
      try Self.checkedWait { waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) }
    }
  }

  /// Blocks (on a background thread) until `pid` ends, reaps it, and gives
  /// how it ended.
  ///
  /// - Parameter pid: The child to reap.
  /// - Returns: The exit code or the signal.
  /// - Throws: `Failure.waitFailed` when `waitpid` failed for a cause other
  ///   than an interrupt.
  private static func reap(_ pid: pid_t) async throws -> Termination {
    try await Self.blocking {
      var status: Int32 = 0
      try Self.checkedWait { waitpid(pid, &status, 0) }
      return Termination(waitStatus: status)
    }
  }

  /// Calls `wait` through ``SystemCall/retryingInterrupts(_:)``, so it runs
  /// again after each interrupt, and throws when it fails for another cause.
  ///
  /// - Parameter wait: A `waitid` or `waitpid` call.
  /// - Throws: `Failure.waitFailed` when `wait` failed for a cause other
  ///   than an interrupt.
  private static func checkedWait(_ wait: () -> Int32) throws {
    let (result, errorNumber) = SystemCall.retryingInterrupts(wait)
    guard result != SystemCall.failure else { throw Failure.waitFailed(errno: errorNumber) }
  }

  // MARK: - Output capture

  /// The size of one read from the pipe.
  private static let readChunkSize = 65_536

  /// Blocks (on a background thread) reading `descriptor` until EOF, into a
  /// tail that obeys `cap`.
  ///
  /// EOF comes when each process that holds the write end has ended: the
  /// child, and each grandchild that inherited it. The group kill at the
  /// timeout is what makes that EOF certain.
  ///
  /// - Parameters:
  ///   - descriptor: The read end of the pipe.
  ///   - cap: The limits of the kept output.
  /// - Returns: The count of all the lines, the kept tail, and the mark.
  private static func readToEnd(descriptor: Int32, cap: OutputCap) async throws
    -> ProcessOutputTail.Capture
  {
    try await Self.blocking {
      var tail = ProcessOutputTail(cap: cap)
      var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
      while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
          SystemCall.retryingInterrupts { read(descriptor, bytes.baseAddress, bytes.count) }.value
        }
        guard count > 0 else {
          return tail.finish()
        }
        tail.append(Data(buffer[0..<count]))
      }
    }
  }

  /// Runs blocking `work` on the global utility-QoS dispatch queue, off the
  /// cooperative pool, and gives its result to the caller. The one place
  /// `awaitExit(_:)`, `reap(_:)` and `readToEnd(descriptor:cap:)` share
  /// this continuation.
  ///
  /// - Parameter work: The blocking work.
  /// - Returns: The result of `work`.
  /// - Throws: The error `work` threw.
  private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try work() })
      }
    }
  }
}

extension ProcessRunner.Termination {
  /// The low seven bits of a `waitpid` status hold the signal that ended the
  /// child. Zero means a normal exit.
  private static let signalMask: Int32 = 0x7f

  /// The exit code stands in the byte above the signal bits.
  private static let exitCodeMask: Int32 = 0xff

  /// The count of bits between the signal bits and the exit code.
  private static let exitCodeShift: Int32 = 8

  /// Decodes a `waitpid` status.
  ///
  /// - Parameter waitStatus: The status `waitpid` gave.
  internal init(waitStatus: Int32) {
    let signal = waitStatus & Self.signalMask
    if signal == 0 {
      self = .exited(code: (waitStatus >> Self.exitCodeShift) & Self.exitCodeMask)
    } else {
      self = .signaled(signal)
    }
  }
}
