/// The result of one doctor run: every finding the applicable components
/// reported, in the order the components were registered in
/// (doctor-plan.md §4).
///
/// The report is the value a renderer draws and a script reads. It holds the
/// findings, it states the worst of them, and it turns that into the exit code
/// of `doctor-plan.md` §5. ``DoctorRunner`` makes one; this initializer is
/// public so a renderer test, or a caller that already holds its findings, can
/// make one too.
///
/// The report is `Codable`, and its JSON form is the one array of findings the
/// `--json` output of `doctor-plan.md` §6 writes. ``worstStatus`` and
/// ``exitCode`` are each derived from ``checks``, so the array is the whole
/// report and no object wraps it. A report that goes through JSON comes back
/// equal.
public struct DoctorReport: Sendable, Equatable, Codable {
    /// Every finding of the run, in the registration order of the components
    /// that reported them.
    public let checks: [HealthCheck]

    /// Creates a report over findings the caller already holds.
    ///
    /// - Parameter checks: Every finding of the run, in the order they are to
    ///   be reported.
    public init(checks: [HealthCheck]) {
        self.checks = checks
    }

    /// Reads a report back from the JSON array ``encode(to:)`` writes.
    ///
    /// - Parameter decoder: The decoder that holds the array of findings.
    /// - Throws: Whatever the decoder throws for a value that is not an array
    ///   of ``HealthCheck``.
    public init(from decoder: any Decoder) throws {
        checks = try decoder.singleValueContainer().decode([HealthCheck].self)
    }

    /// Writes the report as one JSON array of its findings.
    ///
    /// - Parameter encoder: The encoder that receives the array of findings.
    /// - Throws: Whatever the encoder throws.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(checks)
    }

    /// The most serious level any finding reports.
    ///
    /// ``HealthStatus/error`` outranks ``HealthStatus/warning``, which outranks
    /// ``HealthStatus/ok``. A report that holds no finding is
    /// ``HealthStatus/ok``: nothing was checked, so nothing is wrong.
    public var worstStatus: HealthStatus {
        if checks.contains(where: { $0.status == .error }) { return .error }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        return .ok
    }

    /// The process exit code a script reads for this report.
    ///
    /// | Code | Meaning |
    /// |---|---|
    /// | 0 | Every check is ``HealthStatus/ok`` |
    /// | 1 | At least one ``HealthStatus/error`` |
    /// | 5 | At least one ``HealthStatus/warning``, and no error |
    ///
    /// The three codes come from `doctor-plan.md` §5, which is where the
    /// decision is recorded. `1` and `5` were selected to keep the doctor codes
    /// clear of the usage-exit codes of a command-line tool, so a script never
    /// reads a broken configuration as a typing mistake.
    public var exitCode: Int32 {
        switch worstStatus {
        case .ok: Self.okExitCode
        case .error: Self.errorExitCode
        case .warning: Self.warningExitCode
        }
    }

    /// The exit code of a run in which every check passed.
    private static let okExitCode: Int32 = 0

    /// The exit code of a run that holds one broken check or more.
    private static let errorExitCode: Int32 = 1

    /// The exit code of a run that holds one check or more that needs
    /// attention, and nothing broken.
    private static let warningExitCode: Int32 = 5
}
