import Darwin
import Synchronization

/// The one right to kill the process group of one child. That right ends
/// before the reap of the child.
///
/// The child leads its own process group, so its pid is also the identifier
/// of the group. Until the reap, the kernel keeps the pid, also while the
/// child is a zombie. After the reap, the kernel can give the pid to a new
/// process, and that process can lead a new group. A `killpg` with the old
/// pid after the reap can thus kill an unrelated process.
///
/// The reap path calls ``close()`` after the child ended and before the
/// reap. Each kill (``kill()``) reads the state under the same lock and
/// sends nothing after the close. The kill holds the lock while it sends,
/// so a kill that already started ends before the close ends, and thus
/// before the reap starts.
final class ProcessGroupKill: Sendable {
  /// What sends the kill to the group that a pid leads.
  typealias Signal = @Sendable (pid_t) -> Void

  /// The pid of the child, which is the identifier of its process group.
  private let pid: pid_t

  /// `true` until ``close()`` ran.
  private let isOpen = Mutex(true)

  /// What sends the kill.
  private let signal: Signal

  /// Makes the right to kill the group of `pid`.
  ///
  /// - Parameters:
  ///   - pid: The pid of the child, which leads its own process group.
  ///   - signal: What sends the kill.
  init(pid: pid_t, signal: @escaping Signal) {
    self.pid = pid
    self.signal = signal
  }

  /// Kills the group, when the reap path did not close this value yet.
  ///
  /// - Returns: `true` when the kill went out, and `false` when the value
  ///   was closed, so the child can be reaped and its pid can be in use by
  ///   an unrelated process.
  func kill() -> Bool {
    isOpen.withLock { open in
      guard open else { return false }
      signal(pid)
      return true
    }
  }

  /// Closes this value. After this call no ``kill()`` sends anything. A
  /// second call does nothing.
  func close() {
    isOpen.withLock { $0 = false }
  }
}
