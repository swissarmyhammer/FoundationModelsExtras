import Synchronization

/// One warning of a response: an item of `extensions.warnings`.
///
/// A warning tells the agent that the call did its work in a different way than the agent asked, for example that the
/// call ignored a parameter. A warning is not an error: the call ran, and its changes are written.
public struct ResponseWarning: Encodable, Hashable, Sendable {
    /// The text for the agent: what the call did, and how to make the call the correct way.
    public let message: String

    /// A short stable name of the kind of the warning, or `nil` for a warning with no code. The encoder leaves out the
    /// key when the value is `nil`.
    public let code: String?

    /// Makes a warning.
    ///
    /// - Parameters:
    ///   - message: The text for the agent.
    ///   - code: The kind of the warning, or `nil` for a warning with no code.
    public init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}

/// The warnings of one run of a document: the one list that becomes `extensions.warnings` of the response.
///
/// Make a new collector for each run of a call. Thus the warnings of one call do not go into the response of a
/// different call, also when the calls run at the same time. A resolver adds a warning with
/// `await context.warnings.add(…)`. The name rewrite runs in the same run, before the engine runs the rewritten
/// document, so it adds to the same collector. A read does not empty the list, so that a call that fails as a whole
/// after its run gives the same warnings in its error response.
public actor ResponseWarnings {
    /// The warnings that the run added, in the order of the adds.
    public private(set) var list: [ResponseWarning] = []

    /// Makes an empty collector.
    public init() {}

    /// Adds one warning to the list.
    ///
    /// - Parameters:
    ///   - message: The text for the agent.
    ///   - code: The kind of the warning, or `nil` for a warning with no code.
    public func add(_ message: String, code: String? = nil) {
        list.append(ResponseWarning(message: message, code: code))
    }

    /// Adds some warnings to the list, in their order.
    ///
    /// - Parameter added: The warnings, for example the warnings that one mutation field gave.
    public func add(contentsOf added: [ResponseWarning]) {
        list.append(contentsOf: added)
    }
}

/// The warnings that synchronous code gives in one run of a document, for example a resolver that cannot `await`
/// the actor ``ResponseWarnings``.
///
/// The run binds a collector to ``current`` (a task local), the synchronous code adds to it with no `await`, and the
/// run then moves the list into the ``ResponseWarnings`` of its context
/// (``ResolverWarnings/collecting(into:during:)``). A `Mutex` guards the list, and not an actor, because each add is
/// synchronous. The GraphQL engine resolves the fields of one run in child tasks, and a child task reads the task
/// local of its parent, so each add of the run reaches the same collector.
///
/// An add with no bound collector adds no warning.
public final class ResolverWarnings: Sendable {
    /// The collector of the run that runs now, or `nil` when no run binds one.
    @TaskLocal public static var current: ResolverWarnings?

    /// The warnings that the code added, in the order of the adds, with no repeat, behind a lock.
    private let warnings = Mutex<[ResponseWarning]>([])

    /// Makes an empty collector.
    public init() {}

    /// The warnings that the code added, in the order of the adds.
    public var list: [ResponseWarning] {
        warnings.withLock { warnings in warnings }
    }

    /// Adds one warning. A warning with the same message as a warning of the list is not added again, because one run
    /// can resolve the same value more than one time.
    ///
    /// - Parameter warning: The warning.
    public func add(_ warning: ResponseWarning) {
        warnings.withLock { warnings in
            guard !warnings.contains(where: { added in added.message == warning.message }) else {
                return
            }
            warnings.append(warning)
        }
    }

    /// Runs a body with a new collector bound to ``current``, then adds the warnings of the collector to the warnings
    /// of a run.
    ///
    /// - Parameters:
    ///   - responseWarnings: The warnings of the run, for `extensions.warnings`.
    ///   - body: The work of the run, for example the execute of the document.
    /// - Returns: The value of the body.
    /// - Throws: The error of the body. The warnings that the body added before the error are then not moved.
    public static func collecting<Value: Sendable>(
        into responseWarnings: ResponseWarnings,
        during body: () async throws -> Value
    ) async throws -> Value {
        let collector = ResolverWarnings()
        let value = try await $current.withValue(collector) {
            try await body()
        }
        await responseWarnings.add(contentsOf: collector.list)
        return value
    }
}
