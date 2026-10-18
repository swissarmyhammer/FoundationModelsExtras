import Logging
import Synchronization
import ULID

/// The handle of one lease in the ``WorkRegistry`` of a session: work that
/// tooling started and that lives past its call.
///
/// Examples are a background run, a pending shell command, a pending inner
/// call, a notice that waits for its delivery, an MCP call, and a child
/// session that the `agents` tool started. A subagent is one more background
/// tool call.
///
/// Get a lease from ``WorkRegistry/begin(_:id:)`` or from
/// ``ToolContext/beginBackgroundWork(_:id:)``. The lease ends at the first
/// of these:
/// - ``end()``: on settle, on a failure, or on a cancel of the work. Call it
///   in a `defer`, or use ``WorkRegistry/withWork(_:id:isolation:_:)``.
/// - The handle is freed. This is a fallback for a missing ``end()``: the
///   lease ends, and the registry writes a warning log.
///
/// An end is idempotent: a second ``end()`` does nothing. A lease can also
/// wait apart from the session with ``suspend()``, for example while its work
/// waits only for the user, and continue with ``resume()``.
public final class BackgroundWork: Sendable {
    /// The text of the warning log when a handle is freed with no end.
    static let freedWithNoEndMessage = "a background work lease was freed with no end; the lease ends now"

    /// The steps of a lease.
    private enum Phase {
        /// The lease is in the open set of the registry.
        case open

        /// The lease is out of the open set until ``resume()``.
        case suspended

        /// The lease ended. No call changes it again.
        case ended
    }

    /// The kind of the work.
    public let kind: WorkKind

    /// The id of the work.
    public let id: String

    /// The session that owns the lease.
    public let sessionID: ULID

    /// The registry of the lease.
    private let registry: WorkRegistry

    /// The serial number of the lease in its registry.
    private let serial: UInt64

    /// The step of the lease. The lock is held while the registry changes,
    /// thus two calls on one lease cannot cross. The registry never takes
    /// this lock.
    private let phase: Mutex<Phase>

    /// Makes the handle of a lease. ``WorkRegistry/begin(_:id:)`` calls it.
    ///
    /// - Parameters:
    ///   - item: The kind, the id and the session of the lease.
    ///   - registry: The registry of the lease.
    ///   - serial: The serial number of the lease in `registry`.
    ///   - isOpen: `false` for a lease of a closed registry. That lease is
    ///     ended from the start.
    init(item: WorkItem, registry: WorkRegistry, serial: UInt64, isOpen: Bool) {
        self.kind = item.kind
        self.id = item.id
        self.sessionID = item.sessionID
        self.registry = registry
        self.serial = serial
        self.phase = Mutex(isOpen ? .open : .ended)
    }

    deinit {
        let wasEnded = phase.withLock { phase -> Bool in
            defer { phase = .ended }
            return phase == .ended
        }
        guard !wasEnded else { return }
        registry.remove(serial: serial)
        ExtrasTelemetry.makeLogger().warning(
            "\(Self.freedWithNoEndMessage)",
            metadata: [
                ExtrasTelemetry.LogMetadataKey.workKind: .string(kind.rawValue),
                ExtrasTelemetry.LogMetadataKey.sessionID: .string(sessionID.ulidString),
            ])
    }

    /// The kind, the id and the session of the lease.
    public var item: WorkItem {
        WorkItem(kind: kind, id: id, sessionID: sessionID)
    }

    /// Whether the lease ended.
    public var isEnded: Bool {
        phase.withLock { $0 == .ended }
    }

    /// Whether the lease is suspended.
    public var isSuspended: Bool {
        phase.withLock { $0 == .suspended }
    }

    /// Ends the lease. When it was the last open lease of the session, the
    /// registry gives ``WorkTransition/noWork``. A second call does nothing.
    public func end() {
        phase.withLock { phase in
            if phase == .open {
                registry.remove(serial: serial)
            }
            phase = .ended
        }
    }

    /// Takes the open lease out of the open set, with no end. When it was
    /// the last open lease, the registry gives ``WorkTransition/noWork``.
    ///
    /// Use it while the work waits only for the user: the session then has
    /// no work. A suspended or ended lease does not change.
    public func suspend() {
        phase.withLock { phase in
            guard phase == .open else { return }
            registry.remove(serial: serial)
            phase = .suspended
        }
    }

    /// Puts the suspended lease back in the open set. When the session had
    /// no open lease, the registry gives ``WorkTransition/workStarted``. An
    /// open or ended lease does not change.
    public func resume() {
        phase.withLock { phase in
            guard phase == .suspended else { return }
            registry.insert(item, serial: serial)
            phase = .open
        }
    }
}
