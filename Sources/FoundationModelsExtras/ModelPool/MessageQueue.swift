import ULID

/// The identifier of a message that a ``Mailbox`` gives when the message
/// arrives. ``Mailbox/cancel(_:)`` and ``Mailbox/replace(_:with:)`` name a
/// message by it.
public struct MessageID: Hashable, Sendable, CustomStringConvertible {
    /// The generated value of the id.
    private let value: ULID

    /// Makes a new id. Only the mailbox makes ids.
    init() {
        value = ULID()
    }

    /// The id as text.
    public var description: String { value.ulidString }
}

/// The result of ``Mailbox/replace(_:with:)``.
public enum MessageQueueMutationResult: Sendable, Equatable {
    /// The message waited, and the change applied.
    case applied

    /// No waiting message has this id: the pump took the message, or the id
    /// names no waiting message. The change did not apply.
    case alreadySent
}

/// The result of ``Mailbox/cancel(_:)``.
public enum MessageCancellationResult: Sendable, Equatable {
    /// The message waited, and left the mailbox. It never reaches a batch.
    case withdrawn

    /// The pump took the message, and its batch runs. The message gets
    /// `CancellationError` at once. The mailbox does not stop the batch: the
    /// owner of the pump can stop it.
    case cancelledInSubmission

    /// The message has its answer, or the id names no message.
    case alreadyAnswered
}

/// The messages that a ``Mailbox`` owes an answer.
public struct MessageQueueDepth: Sendable, Equatable {
    /// How many messages wait for the pump.
    public let waiting: Int

    /// The messages of the batch that runs, in the order they arrived.
    public let running: [MessageID]

    /// Every message that has no answer yet.
    public var total: Int { waiting + running.count }

    /// Makes a depth.
    ///
    /// - Parameters:
    ///   - waiting: How many messages wait.
    ///   - running: The messages of the batch that runs.
    public init(waiting: Int, running: [MessageID]) {
        self.waiting = waiting
        self.running = running
    }
}
