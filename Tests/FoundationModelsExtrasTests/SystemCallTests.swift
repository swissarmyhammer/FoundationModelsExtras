import Darwin
import Testing

@testable import FoundationModelsExtras

/// Proves the interrupt retry of `SystemCall`: a call that a signal stopped
/// runs again, and any other result comes back at once with its `errno`.
@Suite("System call")
struct SystemCallTests {
  /// The number of interrupts before the call of a test succeeds.
  private static let interruptCount = 2

  /// The value that the call of a test gives when it succeeds.
  private static let successValue: Int32 = 7

  /// A call that fails with `EINTR` runs again until it succeeds, and the
  /// retry gives the value of the success.
  @Test func retriesAnInterruptedCallUntilItSucceeds() {
    var attempts = 0
    let result = SystemCall.retryingInterrupts { () -> Int32 in
      attempts += 1
      guard attempts > Self.interruptCount else {
        errno = EINTR
        return Int32(SystemCall.failure)
      }
      return Self.successValue
    }
    #expect(result.value == Self.successValue)
    #expect(attempts == Self.interruptCount + 1)
  }

  /// A call that fails for a cause other than an interrupt runs once, and
  /// the retry gives the failure and its `errno`.
  @Test func givesAnotherFailureWithItsErrno() {
    var attempts = 0
    let result = SystemCall.retryingInterrupts { () -> Int32 in
      attempts += 1
      errno = EBADF
      return Int32(SystemCall.failure)
    }
    #expect(result.value == Int32(SystemCall.failure))
    #expect(result.errorNumber == EBADF)
    #expect(attempts == 1)
  }

  /// A call that succeeds runs once, even when a stale `EINTR` is left in
  /// `errno`: only a failure is retried.
  @Test func doesNotRetryASuccessWithAStaleInterrupt() {
    var attempts = 0
    let result = SystemCall.retryingInterrupts { () -> Int32 in
      attempts += 1
      errno = EINTR
      return Self.successValue
    }
    #expect(result.value == Self.successValue)
    #expect(attempts == 1)
  }
}
