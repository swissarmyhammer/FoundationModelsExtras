import FoundationModelsExtras

/// The stand-in findings and the exit codes the doctor test suites share.
///
/// `DoctorReportTests` and `DoctorRunnerTests` each build findings, and each
/// reads the exit codes of `doctor-plan.md` §5. The words and the numbers stand
/// here one time, so no test file holds a copy of its own.
enum DoctorTestSupport {
    /// What a stand-in finding states, because the doctor tests read the name
    /// and the status of a finding and never its prose.
    static let findingMessage = "the stand-in component reported"

    /// The action a stand-in `.warning` or `.error` carries, because the two
    /// factory functions require one.
    static let findingFix = "run the stand-in fix"

    /// The group every stand-in finding belongs to.
    static let findingCategory = "probe"

    /// The code §5 gives a run in which every check passed.
    static let passingExitCode: Int32 = 0

    /// The code §5 gives a run that holds one broken check or more.
    static let brokenExitCode: Int32 = 1

    /// The code §5 gives a run that holds one check or more that needs
    /// attention, and nothing broken.
    ///
    /// The three codes are written out here rather than read off the report,
    /// so a change to the production constants fails the tests in place of
    /// travelling through them unseen.
    static let attentionExitCode: Int32 = 5

    /// Builds one finding at `status`, carrying a fix whenever the status
    /// requires one.
    ///
    /// - Parameters:
    ///   - status: The level the finding reports.
    ///   - name: What was checked.
    /// - Returns: A finding at `status`, in the group ``findingCategory``.
    static func finding(_ status: HealthStatus, name: String) -> HealthCheck {
        switch status {
        case .ok:
            .ok(name: name, message: findingMessage, category: findingCategory)
        case .warning:
            .warning(name: name, message: findingMessage, fix: findingFix, category: findingCategory)
        case .error:
            .error(name: name, message: findingMessage, fix: findingFix, category: findingCategory)
        }
    }
}
