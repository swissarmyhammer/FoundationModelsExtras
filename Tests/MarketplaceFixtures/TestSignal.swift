/// A one-shot signal that lets a test wait until another task reached a point
/// in its work.
///
/// The coalescing test uses it to know that the second caller is running and
/// that its next step is the call into the store. Thus the test needs no sleep
/// to order the two callers.
public actor TestSignal {
  /// Whether ``signal()`` already ran.
  private var signalled = false

  /// What to resume when ``signal()`` runs.
  private var observers: [CheckedContinuation<Void, Never>] = []

  /// Makes a signal that no task reached yet.
  public init() {}

  /// Marks the point as reached and wakes every waiter.
  public func signal() {
    signalled = true
    let waiting = observers
    observers.removeAll()
    for observer in waiting {
      observer.resume()
    }
  }

  /// Waits until ``signal()`` runs.
  public func wait() async {
    if signalled {
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      observers.append(continuation)
    }
  }
}
