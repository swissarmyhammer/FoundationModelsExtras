/// A component that reports its own health, so one `doctor` command can ask
/// every part of a program the same question: will this configuration work?
///
/// Each component writes its own checks, because it is the only part that knows
/// its subject matter. This package holds the vocabulary and the runner, and it
/// never learns what a model or an MCP server is (doctor-plan.md §7).
///
/// ``runHealthChecks()`` returns and does not throw (doctor-plan.md §4). A
/// check that cannot run is a finding rather than an error: it reports
/// ``HealthCheck/error(name:message:fix:category:)`` with the reason in its
/// message, so one broken check never stops the other checks.
public protocol Doctorable: Sendable {
    /// What this component is called in the doctor report.
    var doctorName: String { get }

    /// Which group the findings of this component belong to.
    var doctorCategory: String { get }

    /// Whether this component is turned on, and so whether its checks apply.
    ///
    /// A component that is turned off reports nothing. It does not report a
    /// failure. The default implementation answers `true`.
    var isApplicable: Bool { get }

    /// Runs every check this component owns.
    ///
    /// - Returns: One finding for each check. The default implementation
    ///   returns a single ``HealthStatus/ok`` finding that states the component
    ///   wrote no check of its own.
    func runHealthChecks() async -> [HealthCheck]
}

extension Doctorable {
    /// A component applies until it states otherwise.
    public var isApplicable: Bool { true }

    /// The report of a component that wrote no check of its own: one passing
    /// finding, so the component still stands in the doctor report.
    ///
    /// - Returns: One ``HealthStatus/ok`` finding named ``doctorName``, in the
    ///   group ``doctorCategory``.
    public func runHealthChecks() async -> [HealthCheck] {
        [
            .ok(
                name: doctorName,
                message: "this component states no health check of its own",
                category: doctorCategory)
        ]
    }
}
