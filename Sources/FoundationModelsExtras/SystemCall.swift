import Darwin

/// The one retry of a system call that a signal interrupts. `JSONLFile` and
/// `ProcessRunner` run each of their system calls through it.
enum SystemCall {
  /// The value that a system call gives when it fails.
  static let failure = -1

  /// Runs a system call again while it fails with `EINTR`: a signal stopped
  /// it before it did anything. Any other result comes back at once.
  ///
  /// - Parameter call: The system call.
  /// - Returns: The result of the last run, and the `errno` right after it.
  ///   The `errno` means something only when the value is ``failure``.
  static func retryingInterrupts<Value: SignedInteger>(
    _ call: () -> Value
  ) -> (value: Value, errorNumber: Int32) {
    while true {
      let value = call()
      let errorNumber = errno
      guard value == failure, errorNumber == EINTR else {
        return (value, errorNumber)
      }
    }
  }
}
