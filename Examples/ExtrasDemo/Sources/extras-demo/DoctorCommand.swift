import ArgumentParser
import Foundation
import FoundationModelsExtras

/// `extras-demo doctor` — the doctor surface (doctor-plan.md §7): builds a set
/// of demo `Doctorable` components, runs them through a `DoctorRunner`, and
/// reports the findings the way a real `doctor` subcommand does.
///
/// The components are written in this file rather than read off disk, because
/// two claims of `doctor-plan.md` cannot be proved by a unit test and are the
/// whole reason this subcommand exists:
///
/// - **The exit code a script reads.** `0`, `1` and `5` reach a caller only
///   through a real process, so `--scenario` selects a set of components whose
///   worst finding is each of the three in turn.
/// - **The rule that a pipe gets no ANSI.** ``PlainTextDoctorRenderer`` reads
///   the destination itself, so only a run whose standard error IS a pipe
///   proves the plain text a pipe receives.
///
/// The report goes to standard error and the `--json` array goes to standard
/// output, which is the split of `doctor-plan.md` §6: a report is a diagnostic,
/// and the array is what a script reads.
struct DoctorCommand: AsyncParsableCommand {
    /// This subcommand's command-line configuration.
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract:
            "Runs a demo set of Doctorable components, writing the report to stderr and exiting 0, 1 or 5."
    )

    /// Which set of demo components a run registers.
    ///
    /// Each case names the worst finding its set reports, which is what decides
    /// the exit code of the run.
    enum Scenario: String, CaseIterable, ExpressibleByArgument {
        /// Every check passes, so the run exits `0`.
        case ok

        /// The worst finding needs attention, so the run exits `5`.
        case warning

        /// The worst finding is broken, so the run exits `1`.
        case error

        /// One component of each kind together, so one report carries all three
        /// statuses and the run exits `1`.
        case mixed
    }

    /// Which set of demo components to run.
    @Option(
        name: .customLong("scenario"),
        help: "Which demo component set to run: ok, warning, error, or mixed.")
    var scenario: Scenario = .ok

    /// Whether to write the findings as JSON on standard output instead of
    /// drawing the report on standard error.
    @Flag(name: .customLong("json"), help: "Write the findings to stdout as one JSON array.")
    var json = false

    /// Runs the scenario's components and reports their findings.
    ///
    /// The run ends by throwing `ExitCode(report.exitCode)`. ArgumentParser
    /// gives an `ExitCode` its raw value directly and writes nothing of its
    /// own for it, `0` included, so the three codes of `doctor-plan.md` §5
    /// reach the caller unchanged.
    func run() async throws {
        let runner = DoctorRunner(components: Self.components(for: scenario))
        let report = await runner.run()

        if json {
            try FileHandle.standardOutput.write(contentsOf: report.jsonData())
        } else {
            try PlainTextDoctorRenderer().write(report, to: FileHandle.standardError)
        }

        throw ExitCode(report.exitCode)
    }

    // MARK: - The demo components each scenario registers

    /// The components of one scenario, in the order their findings are to be
    /// reported.
    ///
    /// Every scenario registers ``disabledComponent`` as well as its own, so
    /// each run proves the same thing: a component that does not apply is
    /// silent, and it is still a component the program registered.
    ///
    /// - Parameter scenario: Which set to build.
    /// - Returns: The components to hand a ``DoctorRunner``.
    private static func components(for scenario: Scenario) -> [any Doctorable] {
        switch scenario {
        case .ok: [passingComponent, disabledComponent]
        case .warning: [warningComponent, disabledComponent]
        case .error: [errorComponent, disabledComponent]
        case .mixed: [passingComponent, warningComponent, errorComponent, disabledComponent]
        }
    }

    /// The group every demo finding belongs to.
    private static let demoCategory = "demo"

    /// A component whose subject works.
    private static let passingComponent = DemoDoctorComponent(
        doctorName: "ok-component",
        doctorCategory: demoCategory,
        isApplicable: true,
        checks: [
            .ok(
                name: "ok-component",
                message: "the demo subject of this component works",
                category: demoCategory)
        ])

    /// A component whose subject works and needs attention, with a fix of its
    /// own that no other component states.
    private static let warningComponent = DemoDoctorComponent(
        doctorName: "warning-component",
        doctorCategory: demoCategory,
        isApplicable: true,
        checks: [
            .warning(
                name: "warning-component",
                message: "the demo subject of this component works and needs attention",
                fix: "run extras-demo doctor --scenario ok",
                category: demoCategory)
        ])

    /// A component whose subject does not work.
    private static let errorComponent = DemoDoctorComponent(
        doctorName: "error-component",
        doctorCategory: demoCategory,
        isApplicable: true,
        checks: [
            .error(
                name: "error-component",
                message: "the demo subject of this component does not work",
                fix: "run extras-demo doctor --help",
                category: demoCategory)
        ])

    /// A component that is turned off, which every scenario registers.
    ///
    /// Its check is an ``HealthStatus/error`` on purpose. A runner that ever
    /// stopped reading ``Doctorable/isApplicable`` would then put the name
    /// `disabled-component` in the report and turn the run's exit code to `1`,
    /// so the silence this component is registered to prove is a silence a test
    /// can see the loss of.
    private static let disabledComponent = DemoDoctorComponent(
        doctorName: "disabled-component",
        doctorCategory: demoCategory,
        isApplicable: false,
        checks: [
            .error(
                name: "disabled-component",
                message: "this component is turned off and must report nothing",
                fix: "turn this component on",
                category: demoCategory)
        ])
}

/// A health-reporting component whose findings are written out in advance.
///
/// A real ``Doctorable`` reaches its own subject — a directory, a server, a
/// model — and this one holds the answer instead, because the demo's subject is
/// the doctor surface itself rather than anything it could check.
private struct DemoDoctorComponent: Doctorable {
    /// What this component is called in the doctor report.
    let doctorName: String

    /// Which group the findings of this component belong to.
    let doctorCategory: String

    /// Whether this component is turned on, and so whether its checks apply.
    let isApplicable: Bool

    /// What ``runHealthChecks()`` reports.
    let checks: [HealthCheck]

    /// Reports the findings this component was built with.
    ///
    /// - Returns: ``checks``, unchanged.
    func runHealthChecks() async -> [HealthCheck] {
        checks
    }
}
