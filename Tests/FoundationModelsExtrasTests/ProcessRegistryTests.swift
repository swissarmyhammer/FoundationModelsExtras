import Foundation
import FoundationModelsExtras
import Testing

/// Behavioral tests for `ProcessRegistry` and the parameterized `sweep(_:)`
/// backstop: the register/deregister ledger, the group kill a sweep sends,
/// the tolerance a sweep has for an already-dead member, and the stable
/// `global` singleton.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
///
/// Every test builds its own **private** `ProcessRegistry()` — never
/// `ProcessRegistry.global` — so a sweep can never reach a process this test
/// does not own. swift-testing runs a package's suites concurrently in one
/// process, and the global registry can hold pids that belong to another
/// suite.
@Suite struct ProcessRegistryTests {

  /// A failure spawning the child process the sweep tests kill.
  private enum SpawnError: Error {
    /// `posix_spawnattr_init` failed, so no spawn was attempted.
    case attrInit
    /// `posix_spawn` failed with this status.
    case spawn(Int32)
  }

  /// The low seven bits of a `waitpid` status hold the signal that terminated
  /// the child; the remaining bits carry the exit status.
  private let terminatingSignalMask: Int32 = 0x7f

  /// Spawns a real, long-lived `/bin/sleep` child in its **own** process
  /// group, so the child's process-group id equals its pid and a `killpg` of
  /// that pid reaches the child alone.
  ///
  /// - Parameter seconds: How long the child sleeps. `"0"` gives a child that
  ///   exits immediately, which is how a test makes an already-dead pid.
  /// - Returns: The child's pid, which doubles as its process-group id.
  private func spawnKillableChild(seconds: String = "60") throws -> pid_t {
    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { throw SpawnError.attrInit }
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)

    let path = "/bin/sleep"
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup(seconds), nil]
    defer { for case let arg? in argv { free(arg) } }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, path, nil, &attr, argv, environ)
    guard status == 0 else { throw SpawnError.spawn(status) }
    return pid
  }

  /// Reaps `pid` and asserts `SIGKILL` is what ended it.
  ///
  /// `waitpid` blocks until the child exits, so this is a genuine round trip
  /// with no timing race: the sweep either killed the child or this call
  /// never returns.
  ///
  /// - Parameter pid: The pid a sweep was expected to kill.
  private func expectKilledBySweep(_ pid: pid_t) {
    var status: Int32 = 0
    let reaped = waitpid(pid, &status, 0)
    #expect(reaped == pid)
    #expect((status & terminatingSignalMask) == SIGKILL)
  }

  // MARK: - register/deregister lifecycle

  @Test func registerThenDeregisterTracksLiveMembership() {
    let registry = ProcessRegistry()
    let pid: pid_t = 424_242
    #expect(registry.registeredPids.isEmpty)

    registry.register(pid)
    #expect(registry.registeredPids == [pid])

    registry.deregister(pid)
    #expect(registry.registeredPids.isEmpty)
  }

  @Test func deregisteringAnUnregisteredPidIsANoOp() {
    let registry = ProcessRegistry()
    let neverRegisteredPid: pid_t = 999_999
    registry.deregister(neverRegisteredPid)
    #expect(registry.registeredPids.isEmpty)
  }

  // MARK: - sweep(_:) kills every still-registered group

  /// The load-bearing test: `sweep(_:)` on a **private** registry holding a
  /// live child's process-group id `killpg`s it dead.
  @Test func sweepKillsALiveChildInAPrivateRegistry() throws {
    let registry = ProcessRegistry()
    let pid = try spawnKillableChild()
    registry.register(pid)

    // Genuinely alive before the sweep.
    #expect(kill(pid, 0) == 0)

    sweep(registry)

    expectKilledBySweep(pid)
  }

  // MARK: - ESRCH tolerance

  /// An already-dead pid in the registry must not abort the sweep: the rest
  /// of the registered set — a genuinely live pid here — still gets killed.
  @Test func sweepToleratesAnAlreadyDeadPidAndStillKillsOtherLiveMembers() throws {
    let registry = ProcessRegistry()

    let livePid = try spawnKillableChild()
    registry.register(livePid)

    let deadPid = try spawnKillableChild(seconds: "0")
    var reapStatus: Int32 = 0
    _ = waitpid(deadPid, &reapStatus, 0)
    #expect(kill(deadPid, 0) == -1 && errno == ESRCH, "expected \(deadPid) to already be gone")
    registry.register(deadPid)

    sweep(registry)

    expectKilledBySweep(livePid)
  }

  // MARK: - .global installs the atexit sweep exactly once

  @Test func globalRegistryIsAStableSingletonAcrossAccesses() {
    #expect(ProcessRegistry.global === ProcessRegistry.global)
  }
}
