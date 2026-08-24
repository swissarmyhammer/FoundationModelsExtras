import Foundation
import Synchronization

/// A lock-based registry of live process-group leader pids — the family's
/// no-leak backstop for spawned process groups (plan.md §5).
///
/// The owner of a spawned process registers its pid directly after the spawn,
/// and deregisters it after its own teardown did the group kill and the reap.
/// In usual operation this registry is only a live-accounting ledger, empty
/// between spawns. `sweep(_:)` is the backstop for the pids that a *normal*
/// process exit still finds registered — see `ProcessRegistry.global` for the
/// limits of that guarantee.
///
/// It is a plain, lock-based registry rather than an actor because
/// `register(_:)` and `deregister(_:)` must be callable from synchronous,
/// non-`async` contexts — most of all the `atexit` closure this file
/// installs, which cannot `await`.
public final class ProcessRegistry: Sendable {
  /// The live process-group leader pids, behind a lock rather than an actor,
  /// so synchronous callers — the `atexit` closure this file installs — can
  /// register, deregister, and sweep without an `await`.
  private let pids = Mutex<Set<pid_t>>([])

  /// Creates an empty registry.
  public init() {}

  /// Registers `pid` — a process-group leader — as live.
  ///
  /// - Parameter pid: The pid to register.
  public func register(_ pid: pid_t) {
    pids.withLock { _ = $0.insert(pid) }
  }

  /// Deregisters `pid`. A no-op when it is not registered.
  ///
  /// - Parameter pid: The pid to deregister.
  public func deregister(_ pid: pid_t) {
    pids.withLock { _ = $0.remove(pid) }
  }

  /// A snapshot of each registered pid — what `sweep(_:)` kills.
  public var registeredPids: Set<pid_t> {
    pids.withLock { $0 }
  }
}

/// Sends `SIGKILL` to the process group of each pid registered in `registry` —
/// a parameterized sweep, never hardcoded to `ProcessRegistry.global`, so a
/// test can exercise it against a private registry without a risk to pids it
/// does not own.
///
/// A `killpg` of an already-dead group fails with `ESRCH`; that failure is
/// tolerated in silence, and the sweep continues over the rest of the set.
/// `sweep` does not deregister and does not reap: it is a last-resort
/// kill-only backstop, not a part of the register/deregister/reap lifecycle
/// that the owner of a spawned process owns end to end.
///
/// - Parameter registry: The registry whose pids get the group kill.
public func sweep(_ registry: ProcessRegistry) {
  for pid in registry.registeredPids {
    _ = killpg(pid, SIGKILL)
  }
}

/// The process-wide registry the `atexit` sweep below targets. Referenced only
/// from the installer directly below it.
private let globalProcessRegistry = ProcessRegistry()

/// Installs the `atexit` sweep of `globalProcessRegistry`. Swift initializes
/// top-level `let`s lazily, thread-safely, and exactly one time on first
/// access, so `ProcessRegistry.global` starts this installer through the
/// reference to `globalProcessRegistrySweepInstalled` below.
///
/// The closure given to `atexit` must capture nothing — a C function pointer
/// cannot carry captured context — so it references `globalProcessRegistry`
/// directly as a top-level global.
///
/// - Returns: `true`, so a top-level `let` can hold the one-time run.
@discardableResult
private func installGlobalProcessRegistrySweep() -> Bool {
  atexit {
    sweep(globalProcessRegistry)
  }
  return true
}

/// Makes `installGlobalProcessRegistrySweep()` run exactly one time, the first
/// time anything accesses `ProcessRegistry.global`.
private let globalProcessRegistrySweepInstalled = installGlobalProcessRegistrySweep()

extension ProcessRegistry {
  /// The process-wide registry that production code registers spawned pids
  /// into, backstopped by an `atexit`-installed sweep that kills each process
  /// group still registered at a normal process exit.
  ///
  /// **Limitation, stated honestly:** `atexit` runs only on a *normal* process
  /// exit — a return from `main`, or an explicit `exit(_:)`. It does **not**
  /// run on `SIGKILL` or on a crash. This narrows, but does not replace, the
  /// owner's own teardown, which is what guarantees that a spawned process's
  /// group dies and is reaped on every ordinary path the owner controls: an
  /// explicit shutdown, a connection close, the spawned process's own death,
  /// and owner teardown through `deinit`. This registry has something to sweep
  /// only when the host's whole process exits normally while a spawned process
  /// is, for some reason, still registered.
  public static var global: ProcessRegistry {
    _ = globalProcessRegistrySweepInstalled
    return globalProcessRegistry
  }
}
