/// A copy of the agent plan of a running operation, in the shape of the ACP
/// agent plan (https://agentclientprotocol.com/protocol/v2/agent-plan).
///
/// A tool sends a plan to the host on a `.progress` event, in
/// `OperationEvent.plan`. The plan goes one way only: the host sends it to
/// the client, and the model never gets it. Each snapshot holds the full
/// list of entries, so the client replaces the full plan that has the same
/// ``id``.
public struct PlanSnapshot: Codable, Sendable, Equatable {
    /// How important an ``Entry`` is. The wire values agree with ACP.
    public enum Priority: String, Codable, Sendable, Equatable {
        /// The entry is of high importance.
        case high

        /// The entry is of medium importance.
        case medium

        /// The entry is of low importance.
        case low
    }

    /// The state of the work of an ``Entry``. The wire values agree with ACP.
    public enum Status: String, Codable, Sendable, Equatable {
        /// The work did not start.
        case pending

        /// The work is in progress. Carried on the wire as `in_progress`.
        case inProgress = "in_progress"

        /// The work is done.
        case completed

        /// The work stopped before it was done.
        case cancelled
    }

    /// One task of the plan.
    public struct Entry: Codable, Sendable, Equatable {
        /// The human-readable text of the task.
        public let content: String

        /// How important the task is.
        public let priority: Priority

        /// The state of the work of the task.
        public let status: Status

        /// Creates an entry from its fields.
        ///
        /// - Parameters:
        ///   - content: The human-readable text of the task.
        ///   - priority: How important the task is.
        ///   - status: The state of the work of the task.
        public init(content: String, priority: Priority, status: Status) {
            self.content = content
            self.priority = priority
            self.status = status
        }
    }

    /// The identifier of the plan. A session can have more than one plan.
    /// An update replaces the plan that has this identifier.
    public let id: String

    /// The full list of entries, in order. Never a partial list.
    public let entries: [Entry]

    /// Creates a snapshot from its fields.
    ///
    /// - Parameters:
    ///   - id: The identifier of the plan.
    ///   - entries: The full list of entries, in order.
    public init(id: String, entries: [Entry]) {
        self.id = id
        self.entries = entries
    }
}
