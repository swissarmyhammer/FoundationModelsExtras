import Foundation
import FoundationModels
import FoundationModelsExtras
import Operations
import ULID

// The tools that the tool-hosting suite mounts under a real model session.
// Each tool returns a code that the model cannot guess, thus an answer that
// holds the code is an answer that used the tool result.

/// The arguments of each fixture tool that works on one named thing.
@Generable
struct NamedThingArguments {
    /// The name of the thing.
    @Guide(description: "The name that the user gave")
    var name: String
}

// MARK: - Run to completion

/// What a tool read from `ToolContext.current` in one call.
struct ContextReading: Sendable, Equatable {
    /// The session of the context, or `nil` when the call had no context.
    let sessionID: ULID?
    /// The tool name of the context, or `nil` when the call had no context.
    let tool: String?
    /// The completion token of the call, or `nil` when the call had no context.
    let completionToken: String?

    /// Reads `context`.
    ///
    /// - Parameter context: The context of the call, or `nil`.
    init(_ context: ToolContext?) {
        sessionID = context?.sessionID
        tool = context?.tool
        completionToken = context?.completionToken
    }
}

/// An in-band tool: it reads its context, posts one progress event, and
/// returns the code of a vault.
struct VaultCodeTool: Tool {
    /// The detail of the progress event of each call.
    static let progressDetail = "reading the vault register"

    /// The code that each call returns.
    static let code = "AMBER-FALCON-73"

    let name = "look_up_vault_code"
    let description = "Looks up the code of a vault by the name of the vault."

    /// The context that each call read, in call order.
    let readings: EventLog<ContextReading>

    /// Records the context, posts the progress event, and returns the code.
    ///
    /// - Parameter arguments: The vault.
    /// - Returns: A sentence with the code.
    func call(arguments: NamedThingArguments) async throws -> String {
        let context = ToolContext.current
        await readings.append(ContextReading(context))
        await context?.progress(Self.progressDetail)
        return "The code of the vault \(arguments.name) is \(Self.code)."
    }
}

// MARK: - Background runs

/// A background tool: each call starts a scan that ends after a short time.
/// Its pending envelope has the default `next` text, which ends with
/// ``PendingRunEnvelope/pendingWorkInstruction``.
struct ArchiveScanTool: Tool, BackgroundTool {
    /// The milliseconds of ``workDuration``.
    private static let workMilliseconds = 500

    /// How long each scan works.
    private static let workDuration = Duration.milliseconds(workMilliseconds)

    /// The code of the report of each scan.
    static let code = "COPPER-HERON-58"

    let name = "start_archive_scan"
    let description = "Starts a scan of an archive by the name of the archive."
    let mount: ToolMount? = ToolMount(mode: .background)

    /// Works for a short time, and returns the report.
    ///
    /// - Parameter arguments: The archive.
    /// - Returns: The report of the scan.
    func call(arguments: NamedThingArguments) async throws -> String {
        try await Task.sleep(for: Self.workDuration)
        return Self.report
    }

    /// The report of each scan.
    static let report = "The scan report code is \(code)."
}

/// A background tool that states no grace: each scan ends at once, far inside
/// the default settle period of the host. Thus the call answers with the
/// report itself, the same as a synchronous call, and with no envelope.
struct QuickScanTool: Tool, BackgroundTool {
    /// The code of the report of each scan.
    static let code = "SILVER-OTTER-26"

    /// The report of each scan.
    static let report = "The quick scan report code is \(code)."

    let name = "scan_small_archive"
    let description = "Scans a small archive by the name of the archive, and gives the report."
    let mount: ToolMount? = ToolMount(mode: .background)

    /// Returns the report at once.
    ///
    /// - Parameter arguments: The archive.
    /// - Returns: The report of the scan.
    func call(arguments: NamedThingArguments) async throws -> String {
        Self.report
    }
}

/// A background tool whose scan works until a cancel stops it. Its pending
/// envelope has the default `next` text, which ends with
/// ``PendingRunEnvelope/pendingWorkInstruction``.
struct EndlessScanTool: Tool, BackgroundTool {
    /// How long each scan works when nothing cancels it: longer than a test
    /// can run.
    private static let workDuration = Duration.seconds(RealModelSuites.testTimeLimitMinutes * secondsPerMinute)

    let name = "start_full_scan"
    let description = "Starts a full scan of an archive by the name of the archive."
    let mount: ToolMount? = ToolMount(mode: .background)

    /// Sleeps until a cancel stops the sleep.
    ///
    /// - Parameter arguments: The archive.
    /// - Returns: Never before a cancel.
    /// - Throws: `CancellationError` at the cancel.
    func call(arguments: NamedThingArguments) async throws -> String {
        try await Task.sleep(for: Self.workDuration)
        return "The full scan of \(arguments.name) ended."
    }
}

/// The seconds in one minute.
private let secondsPerMinute = 60

// MARK: - Timeout and failure

/// A tool that works much longer than its timeout and ignores the cancel.
struct StuckRecordTool: Tool {
    /// The seconds of ``workDuration``.
    static let workSeconds = 120

    /// How long each call works. The cancel does not stop it.
    private static let workDuration = Duration.seconds(workSeconds)

    let name = "look_up_record"
    let description = "Looks up a record by the name of the record."

    /// Works for ``workDuration`` in a detached task, which does not get the
    /// cancel of the call, and returns after it.
    ///
    /// - Parameter arguments: The record.
    /// - Returns: A sentence, after ``workDuration``.
    func call(arguments: NamedThingArguments) async throws -> String {
        await Task.detached { try? await Task.sleep(for: Self.workDuration) }.value
        return "The record \(arguments.name) is ready."
    }
}

/// The failure of ``LockedArchiveTool``.
struct ArchiveLockedError: Error, CustomStringConvertible {
    /// The error code that the text of the failure holds.
    static let code = "LOCK-4417"

    /// The archive that is locked.
    let archive: String

    /// The text that the model reads.
    var description: String {
        "The archive \(archive) is locked. The error code is \(Self.code)."
    }
}

/// A tool whose each call fails.
struct LockedArchiveTool: Tool {
    let name = "open_archive"
    let description = "Opens an archive by the name of the archive."

    /// Fails.
    ///
    /// - Parameter arguments: The archive.
    /// - Returns: Never.
    /// - Throws: ``ArchiveLockedError`` always.
    func call(arguments: NamedThingArguments) async throws -> String {
        throw ArchiveLockedError(archive: arguments.name)
    }
}

// MARK: - Per-call mounts

/// The arguments of ``JobTool``.
@Generable
struct JobArguments {
    /// The job to run.
    @Guide(description: "The job to run", .anyOf([JobTool.scanJob, JobTool.countJob]))
    var job: String
}

/// A tool that runs the scan job in the background and the count job in band.
struct JobTool: Tool, BackgroundTool {
    /// The job that runs in the background.
    static let scanJob = "scan"

    /// The job that runs in band.
    static let countJob = "count"

    /// The name of the argument that names the job.
    private static let jobProperty = "job"

    /// The code that the result of the scan job holds.
    static let scanCode = "TEAL-BADGER-91"

    /// The code that the result of the count job holds.
    static let countCode = "PLUM-WALRUS-35"

    /// The result of the scan job.
    static let scanResult = "The scan job result is \(scanCode)."

    /// The result of the count job.
    static let countResult = "The count job result is \(countCode)."

    let name = "run_job"
    let description = "Runs one job: scan or count."

    /// The mount of one call: background for the scan job, synchronous for
    /// each other job.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The mount of the call.
    func mount(for arguments: GeneratedContent) -> ToolMount? {
        let job = try? arguments.value(String.self, forProperty: Self.jobProperty)
        return job == Self.scanJob ? ToolMount(mode: .background) : .synchronous
    }

    /// Returns the result of the job.
    ///
    /// - Parameter arguments: The job.
    /// - Returns: The result.
    func call(arguments: JobArguments) async throws -> String {
        arguments.job == Self.scanJob ? Self.scanResult : Self.countResult
    }
}

/// The shared context of the archive operations. It holds no state.
struct ArchiveOperationsContext: Sendable {}

/// The output of one archive operation.
struct ArchiveReport: Encodable, Sendable {
    /// The code of the report.
    let code: String
}

/// `start scan`: a background operation.
@Generable
@Operation(verb: "start", noun: "scan", description: "Start a scan of the archive", mount: ToolMount(mode: .background))
struct StartScanOperation {
    /// The code of the report of the scan.
    static let code = "OLIVE-MARTEN-47"
}

extension StartScanOperation {
    /// Returns the report of the scan.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The report.
    func execute(in context: ArchiveOperationsContext) async -> ArchiveReport {
        ArchiveReport(code: Self.code)
    }
}

/// `count files`: a synchronous operation.
@Generable
@Operation(verb: "count", noun: "files", description: "Count the files of the archive")
struct CountFilesOperation {
    /// The code of the report of the count.
    static let code = "IVORY-PELICAN-62"
}

extension CountFilesOperation {
    /// Returns the report of the count.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The report.
    func execute(in context: ArchiveOperationsContext) async -> ArchiveReport {
        ArchiveReport(code: Self.code)
    }
}

/// The `archive` operation tool.
enum ArchiveOperationTool {
    /// The name of the tool.
    static let name = "archive"

    /// Fuses the two archive operations into one tool.
    ///
    /// - Returns: The tool.
    /// - Throws: What `OperationTool.init` throws when the fused schema is not
    ///   valid. These two operations do not make it throw.
    static func make() throws -> OperationTool<ArchiveOperationsContext> {
        try OperationTool(
            name: name,
            description: "Works on the archive: start scan, or count files.",
            context: ArchiveOperationsContext(),
            operations: [AnyOperation(StartScanOperation.self), AnyOperation(CountFilesOperation.self)])
    }
}
