import Synchronization
import ULID

/// The kind of a ``BackgroundWork`` lease.
///
/// The set of kinds is open. This package gives the kinds of the tooling as
/// static values. A host gives its own kinds with ``init(_:)``, for example
/// the generation, the queued mail and the compaction of a session. Two kinds
/// are equal when their raw values are equal.
public struct WorkKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    /// The name of the kind.
    public let rawValue: String

    /// Makes a kind with the name `rawValue`.
    ///
    /// - Parameter rawValue: The name of the kind.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Makes a kind with the name `rawValue`.
    ///
    /// - Parameter rawValue: The name of the kind.
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Makes a kind from a string literal.
    ///
    /// - Parameter value: The name of the kind.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// Makes a kind from the encoded name.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: When the value is not a string.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the name of the kind as one string.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: The error of the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The name of the kind.
    public var description: String { rawValue }

    /// A background run of the run plane, from its start to its settle.
    public static let backgroundRun = WorkKind("backgroundRun")

    /// A shell command that continues after the call that started it.
    public static let shellCommand = WorkKind("shellCommand")

    /// An inner tool call that continues after the call that started it, for
    /// example an inner call of a script runner.
    public static let innerCall = WorkKind("innerCall")

    /// A notice that waits for its delivery to the session.
    public static let noticeDelivery = WorkKind("noticeDelivery")

    /// A call to an MCP server.
    public static let mcpCall = WorkKind("mcpCall")

    /// A child session that a tool call started, for example a subagent of
    /// the `agents` tool. The lease is in the registry of the parent. The
    /// work of the child is in the registry of the child.
    public static let childSession = WorkKind("childSession")
}

/// One open lease in a ``WorkRegistry``: what holds the session busy.
public struct WorkItem: Sendable, Hashable {
    /// The kind of the lease.
    public let kind: WorkKind

    /// The id of the lease, for example the completion token of a run.
    public let id: String

    /// The session that owns the lease.
    public let sessionID: ULID

    /// Makes an item.
    ///
    /// - Parameters:
    ///   - kind: The kind of the lease.
    ///   - id: The id of the lease.
    ///   - sessionID: The session that owns the lease.
    public init(kind: WorkKind, id: String, sessionID: ULID) {
        self.kind = kind
        self.id = id
        self.sessionID = sessionID
    }
}

/// A change of a session between work and no work.
public enum WorkTransition: Sendable, Equatable {
    /// The session had no open lease, and now it has one.
    case workStarted

    /// The last open lease of the session ended, or a suspend took it out.
    case noWork
}

/// The set of the open ``BackgroundWork`` leases of one session.
///
/// Each session has its own registry. A child session has a registry of its
/// own. A lease of the child never goes into the registry of the parent: the
/// parent has only the lease of the tool call that started the child.
///
/// The registry gives one ``WorkTransition`` for each change: the first open
/// lease gives ``WorkTransition/workStarted``, and the end of the last open
/// lease gives ``WorkTransition/noWork``. The two transitions alternate, also
/// when many tasks begin and end leases at the same time. A lock holds the
/// state, thus ``begin(_:id:)`` is synchronous: the lease is open before the
/// work gives its first output.
///
/// The registry holds only work. Housekeeping is not work: an index, a file
/// watcher or a language-server daemon never takes a lease.
///
/// After ``close()``, the registry gives no transition, each stream ends, and
/// a new lease is not work.
public final class WorkRegistry: Sendable {
    /// One task that waits in ``awaitNoWork()``.
    private typealias NoWorkWaiter = CheckedContinuation<Void, Never>

    /// One test task that waits until enough tasks wait for no work.
    private struct WaiterCountWatch {
        /// The number of waits that ends the watch.
        let count: Int

        /// Resumes the test task.
        let continuation: CheckedContinuation<Void, Never>
    }

    /// The state behind the lock.
    private struct State {
        /// Each open lease, by its serial number. A lower serial began first.
        var open: [UInt64: WorkItem] = [:]

        /// The serial number of the next lease.
        var nextSerial: UInt64 = 0

        /// Each stream of transitions, by its id.
        var subscribers: [UInt64: AsyncStream<WorkTransition>.Continuation] = [:]

        /// Each task that waits for no work, by the id of its wait.
        var noWorkWaiters: [UInt64: NoWorkWaiter] = [:]

        /// Each test task that waits for a number of waits.
        var waiterCountWatches: [WaiterCountWatch] = []

        /// The id of the next stream or wait.
        var nextID: UInt64 = 0

        /// Whether ``close()`` ran.
        var isClosed = false

        /// Gives a new id.
        ///
        /// - Returns: The id.
        mutating func makeID() -> UInt64 {
            nextID += 1
            return nextID
        }

        /// Sends `transition` to each stream.
        ///
        /// - Parameter transition: The transition.
        func send(_ transition: WorkTransition) {
            for subscriber in subscribers.values {
                subscriber.yield(transition)
            }
        }

        /// Takes each test watch whose count the waits reached.
        ///
        /// - Returns: The watches to resume.
        mutating func takeReachedWatches() -> [WaiterCountWatch] {
            let reached = waiterCountWatches.filter { $0.count <= noWorkWaiters.count }
            waiterCountWatches.removeAll { $0.count <= noWorkWaiters.count }
            return reached
        }
    }

    /// The session of this registry.
    public let sessionID: ULID

    /// The state of this registry.
    private let state = Mutex(State())

    /// Makes an empty registry for the session `sessionID`.
    ///
    /// - Parameter sessionID: The session of the registry. Each lease of the
    ///   registry has this session as its owner.
    public init(sessionID: ULID) {
        self.sessionID = sessionID
    }

    // MARK: - Leases

    /// Begins a lease of `kind` under `id`, and gives its handle.
    ///
    /// This call is synchronous, thus the lease is open when the call
    /// returns. When the registry had no open lease, the streams get
    /// ``WorkTransition/workStarted`` before the call returns.
    ///
    /// The lease ends at ``BackgroundWork/end()``, or when the handle is
    /// freed. Two leases can have the same id: each one is a lease of its own.
    /// After ``close()``, the lease is ended at once, and it is not work.
    ///
    /// - Parameters:
    ///   - kind: The kind of the work.
    ///   - id: The id of the work, for example a completion token.
    /// - Returns: The handle of the lease.
    public func begin(_ kind: WorkKind, id: String) -> BackgroundWork {
        let serial: UInt64? = state.withLock { state in
            guard !state.isClosed else { return nil }
            state.nextSerial += 1
            return state.nextSerial
        }
        let item = WorkItem(kind: kind, id: id, sessionID: sessionID)
        guard let serial else {
            return BackgroundWork(item: item, registry: self, serial: 0, isOpen: false)
        }
        let lease = BackgroundWork(item: item, registry: self, serial: serial, isOpen: true)
        insert(item, serial: serial)
        return lease
    }

    /// Runs `body` with a lease of `kind` under `id`. The lease ends when
    /// `body` returns or throws.
    ///
    /// - Parameters:
    ///   - kind: The kind of the work.
    ///   - id: The id of the work.
    ///   - isolation: The actor of the caller.
    ///   - body: The work.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    public func withWork<Value>(
        _ kind: WorkKind,
        id: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        let lease = begin(kind, id: id)
        defer { lease.end() }
        return try await body()
    }

    /// Puts the lease `serial` in the open set, and gives
    /// ``WorkTransition/workStarted`` when the set was empty. A closed
    /// registry does nothing.
    ///
    /// - Parameters:
    ///   - item: The lease.
    ///   - serial: The serial number of the lease.
    func insert(_ item: WorkItem, serial: UInt64) {
        state.withLock { state in
            guard !state.isClosed, state.open[serial] == nil else { return }
            state.open[serial] = item
            if state.open.count == 1 {
                state.send(.workStarted)
            }
        }
    }

    /// Takes the lease `serial` out of the open set, and gives
    /// ``WorkTransition/noWork`` when the set becomes empty. Each task that
    /// waits for no work then resumes. A lease that is not open does
    /// nothing.
    ///
    /// - Parameter serial: The serial number of the lease.
    func remove(serial: UInt64) {
        let waiters: [NoWorkWaiter] = state.withLock { state in
            guard !state.isClosed, state.open.removeValue(forKey: serial) != nil, state.open.isEmpty else {
                return []
            }
            state.send(.noWork)
            let waiters = Array(state.noWorkWaiters.values)
            state.noWorkWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - The state

    /// Whether one or more leases are open.
    public var hasWork: Bool {
        state.withLock { !$0.open.isEmpty }
    }

    /// Each open lease, in begin order: what holds the session busy now. A
    /// suspended lease is not in the list.
    public var openWork: [WorkItem] {
        state.withLock { state in
            state.open.sorted { $0.key < $1.key }.map(\.value)
        }
    }

    /// Whether ``close()`` ran.
    public var isClosed: Bool {
        state.withLock(\.isClosed)
    }

    /// A stream of each transition from now on.
    ///
    /// Each call gives a stream of its own, and each stream gets each
    /// transition, in order. The stream ends at ``close()``. A stream of a
    /// closed registry ends at once.
    ///
    /// - Parameter includingCurrent: When `true`, the stream starts with the
    ///   current state: ``WorkTransition/workStarted`` when a lease is open,
    ///   else ``WorkTransition/noWork``. Thus a subscriber knows the state
    ///   with no race between a read and the subscribe.
    /// - Returns: The stream.
    public func transitions(includingCurrent: Bool = false) -> AsyncStream<WorkTransition> {
        let (stream, continuation) = AsyncStream.makeStream(of: WorkTransition.self, bufferingPolicy: .unbounded)
        let id: UInt64? = state.withLock { state in
            guard !state.isClosed else { return nil }
            if includingCurrent {
                continuation.yield(state.open.isEmpty ? .noWork : .workStarted)
            }
            let id = state.makeID()
            state.subscribers[id] = continuation
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Waits until no lease is open, or until ``close()``. Returns at once
    /// when no lease is open. A cancel of the task ends the wait.
    public func awaitNoWork() async {
        let id = state.withLock { $0.makeID() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: NoWorkWaiter) in
                let (resumeNow, watches): (Bool, [WaiterCountWatch]) = state.withLock { state in
                    // A cancel sets the flag before its handler takes this
                    // lock, thus this check or the handler sees the cancel.
                    guard !state.open.isEmpty, !state.isClosed, !Task.isCancelled else { return (true, []) }
                    state.noWorkWaiters[id] = continuation
                    return (false, state.takeReachedWatches())
                }
                watches.forEach { $0.continuation.resume() }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.noWorkWaiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// Ends the registry: each stream ends, each wait for no work resumes,
    /// and each open lease leaves the set with no transition. A second call
    /// does nothing.
    public func close() {
        let (subscribers, waiters, watches) = state.withLock { state in
            guard !state.isClosed else {
                return ([AsyncStream<WorkTransition>.Continuation](), [NoWorkWaiter](), [WaiterCountWatch]())
            }
            state.isClosed = true
            state.open.removeAll()
            defer {
                state.subscribers.removeAll()
                state.noWorkWaiters.removeAll()
                state.waiterCountWatches.removeAll()
            }
            return (Array(state.subscribers.values), Array(state.noWorkWaiters.values), state.waiterCountWatches)
        }
        subscribers.forEach { $0.finish() }
        waiters.forEach { $0.resume() }
        watches.forEach { $0.continuation.resume() }
    }

    // MARK: - Tests

    /// Waits until at least `count` tasks wait in ``awaitNoWork()``, or until
    /// ``close()``. A test calls it before it ends the last lease, so that it
    /// knows that the wait started first.
    ///
    /// - Parameter count: The number of waits.
    func waitForNoWorkWaiters(atLeast count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isClosed, state.noWorkWaiters.count < count else { return true }
                state.waiterCountWatches.append(WaiterCountWatch(count: count, continuation: continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
