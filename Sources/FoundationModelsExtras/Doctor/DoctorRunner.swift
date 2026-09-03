/// Collects the health checks of a list of components into one
/// ``DoctorReport`` (doctor-plan.md §4).
///
/// The runner is what a `doctor` subcommand builds: it takes the components a
/// program registers, asks each applicable one for its findings, and returns
/// the report. It knows nothing about what the components check.
///
/// The components run **at the same time**, in a task group, because a doctor
/// that reaches four servers one after the other is slow for no reason. The
/// report still keeps the order the components were registered in, so the
/// output of two runs of the same configuration reads the same way.
public struct DoctorRunner: Sendable {
    /// Every component that was registered, in the order it was registered.
    ///
    /// A component that does not apply stays in this list. It reports nothing
    /// (see ``run()``), and it is still a component the program registered.
    public let components: [any Doctorable]

    /// Creates a runner over the components a program registers.
    ///
    /// - Parameter components: The components to ask, in the order their
    ///   findings are to be reported.
    public init(components: [any Doctorable]) {
        self.components = components
    }

    /// Asks every applicable component for its findings, at the same time, and
    /// gathers them into one report.
    ///
    /// A component whose ``Doctorable/isApplicable`` is `false` is skipped: it
    /// contributes no finding, and that is not a failure. Because
    /// ``Doctorable/runHealthChecks()`` returns and does not throw, one broken
    /// component never stops the findings of the others.
    ///
    /// - Returns: A report holding the findings of every applicable component,
    ///   in the registration order of ``components`` — never in the order the
    ///   components happened to finish.
    public func run() async -> DoctorReport {
        let applicable = components.enumerated().filter { $0.element.isApplicable }
        let collected = await withTaskGroup(of: RegisteredFindings.self) { group in
            for (position, component) in applicable {
                group.addTask {
                    RegisteredFindings(position: position, checks: await component.runHealthChecks())
                }
            }

            return await group.reduce(into: [RegisteredFindings]()) { gathered, findings in
                gathered.append(findings)
            }
        }

        let ordered = collected.sorted { $0.position < $1.position }
        return DoctorReport(checks: ordered.flatMap(\.checks))
    }

    /// The findings of one component, tagged with where that component stands
    /// in ``components``.
    ///
    /// The children of the task group finish in whatever order they finish in,
    /// so each one carries its registration position home and the run sorts on
    /// it. The position is read before the applicability filter, so skipping a
    /// component never shifts the ones behind it.
    private struct RegisteredFindings: Sendable {
        /// Where the reporting component stands in ``DoctorRunner/components``.
        let position: Int

        /// What that component found.
        let checks: [HealthCheck]
    }
}
