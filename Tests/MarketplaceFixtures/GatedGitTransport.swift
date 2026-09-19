import Foundation
import Marketplace

/// A ``GitTransport`` that holds a call until the test releases it, or until
/// the task of the call is cancelled (marketplace.md §13).
///
/// The gate wraps another transport, thus it adds no counting of its own: a
/// test puts it over ``RecordingGitTransport`` and reads the counts there.
/// A held call lets a test act while a check or a fetch is in progress, which
/// is what the coalescing, the `stop()`, and the `fetchTimeout` tests need.
public actor GatedGitTransport: GitTransport {
  /// What the gate does with one call.
  public enum Behavior: Sendable {
    /// The call goes straight to the wrapped transport.
    case pass

    /// The call waits for ``release()``, then goes to the wrapped
    /// transport.
    case holdThenPass

    /// The call waits until its task is cancelled. It never reaches the
    /// wrapped transport.
    case holdUntilCancelled
  }

  /// One call of the transport.
  public enum Call: Sendable, Hashable {
    /// ``GitTransport/remoteHead(url:ref:credentials:)``.
    case remoteHead

    /// ``GitTransport/fetch(url:revision:intoBareRepository:credentials:)``.
    case fetch
  }

  /// The transport that does the work of a call that the gate lets through.
  private let base: any GitTransport

  /// What the gate does with a remote-head call.
  private var remoteHeadBehavior: Behavior

  /// What the gate does with a fetch call.
  private var fetchBehavior: Behavior

  /// How many times each call entered the gate.
  private var entries: [Call: Int] = [:]

  /// Whether ``release()`` already ran.
  private var released = false

  /// What to resume when ``release()`` runs, by id.
  private var held: [Int: CheckedContinuation<Void, any Error>] = [:]

  /// The id of each held call whose task was cancelled before the call
  /// registered itself.
  private var cancelled: Set<Int> = []

  /// The id that the next held call gets.
  private var nextID = 0

  /// What to resume when a call enters the gate.
  private var observers: [CheckedContinuation<Void, Never>] = []

  /// Makes a gate over another transport.
  ///
  /// - Parameters:
  ///   - base: The transport that does the work.
  ///   - remoteHead: What the gate does with a remote-head call. The default
  ///     is ``Behavior/pass``.
  ///   - fetch: What the gate does with a fetch call. The default is
  ///     ``Behavior/pass``.
  public init(wrapping base: any GitTransport, remoteHead: Behavior = .pass, fetch: Behavior = .pass) {
    self.base = base
    remoteHeadBehavior = remoteHead
    fetchBehavior = fetch
  }

  /// Lets every held call, and every later call, through to the wrapped
  /// transport.
  ///
  /// A call with ``Behavior/holdUntilCancelled`` is not released: only a
  /// cancellation ends it.
  public func release() {
    released = true
    let waiting = held.values
    held.removeAll()
    for continuation in waiting {
      continuation.resume()
    }
  }

  /// Replaces what the gate does with one call, for every later call.
  ///
  /// - Parameters:
  ///   - behavior: What the gate does from now on.
  ///   - call: The call that the new behavior belongs to.
  public func setBehavior(_ behavior: Behavior, of call: Call) {
    switch call {
    case .remoteHead:
      remoteHeadBehavior = behavior
    case .fetch:
      fetchBehavior = behavior
    }
  }

  /// How many times one call entered the gate.
  ///
  /// - Parameter call: The call to count.
  /// - Returns: The number of entries.
  public func entryCount(of call: Call) -> Int {
    entries[call] ?? 0
  }

  /// Waits until one call entered the gate at least `count` times.
  ///
  /// - Parameters:
  ///   - call: The call to wait for.
  ///   - count: How many entries the wait needs. The default is one.
  public func waitForEntry(of call: Call, count: Int = 1) async {
    while (entries[call] ?? 0) < count {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        observers.append(continuation)
      }
    }
  }

  public func remoteHead(
    url: String, ref: String, credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
  ) async throws -> String {
    try await gate(call: .remoteHead, behavior: remoteHeadBehavior)
    return try await base.remoteHead(url: url, ref: ref, credentials: credentials)
  }

  public func fetch(
    url: String, revision: String, intoBareRepository repositoryURL: URL,
    credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
  ) async throws -> String {
    try await gate(call: .fetch, behavior: fetchBehavior)
    return try await base.fetch(
      url: url, revision: revision, intoBareRepository: repositoryURL, credentials: credentials)
  }

  /// Records one entry and holds the call when its behavior says so.
  ///
  /// - Parameters:
  ///   - call: The call that entered.
  ///   - behavior: What the gate does with it.
  /// - Throws: ``GitTransportError/cancelled`` when the task of the call is
  ///   cancelled while the gate holds it.
  private func gate(call: Call, behavior: Behavior) async throws {
    entries[call, default: 0] += 1
    notifyObservers()
    switch behavior {
    case .pass:
      return
    case .holdThenPass:
      if released {
        return
      }
      try await hold(untilRelease: true)
    case .holdUntilCancelled:
      try await hold(untilRelease: false)
    }
  }

  /// Waits until ``release()`` runs, or until the task is cancelled.
  ///
  /// - Parameter untilRelease: Whether ``release()`` ends the wait. When it
  ///   is `false`, only a cancellation ends it.
  /// - Throws: ``GitTransportError/cancelled`` when the task is cancelled.
  private func hold(untilRelease: Bool) async throws {
    let id = nextID
    nextID += 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if cancelled.remove(id) != nil {
          continuation.resume(throwing: GitTransportError.cancelled)
          return
        }
        if untilRelease, released {
          continuation.resume()
          return
        }
        held[id] = continuation
      }
    } onCancel: {
      Task { await self.cancelHold(id: id) }
    }
  }

  /// Ends one held call with a cancellation, or records the cancellation
  /// when the call did not register itself yet.
  ///
  /// - Parameter id: The held call to cancel.
  private func cancelHold(id: Int) {
    guard let continuation = held.removeValue(forKey: id) else {
      cancelled.insert(id)
      return
    }
    continuation.resume(throwing: GitTransportError.cancelled)
  }

  /// Resumes every waiter of ``waitForEntry(of:count:)``.
  private func notifyObservers() {
    let waiting = observers
    observers.removeAll()
    for observer in waiting {
      observer.resume()
    }
  }
}
