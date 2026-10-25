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

/// A background tool: each call starts a scan that works until the test opens
/// a gate. Its pending envelope has the default `next` text, which ends with
/// the status line `Waiting on <op> (<token>).`
struct ArchiveScanTool: Tool, BackgroundTool {
    /// The code of the report of each scan.
    static let code = "COPPER-HERON-58"

    let name = "start_archive_scan"
    let description = "Starts a scan of an archive by the name of the archive."
    let mount: ToolMount? = ToolMount(mode: .background)

    /// The gate that holds each scan. The test opens it after the call gave
    /// its pending envelope, thus the run continues after the call.
    let gate: Latch

    /// Works until the gate opens, and returns the report.
    ///
    /// - Parameter arguments: The archive.
    /// - Returns: The report of the scan.
    /// - Throws: `CancellationError` when the run is cancelled first.
    func call(arguments: NamedThingArguments) async throws -> String {
        await gate.waitUntilOpen()
        try Task.checkCancellation()
        return Self.report
    }

    /// The report of each scan.
    static let report = "The scan report code is \(code)."
}

// MARK: - Timeout and failure

/// A tool that works past its timeout and ignores the cancel.
struct StuckRecordTool: Tool {
    let name = "look_up_record"
    let description = "Looks up a record by the name of the record."

    /// The gate that holds each call. The test opens it only after its
    /// expectations, thus a model call that returned did not wait for the
    /// tool.
    let gate: Latch

    /// Works in a detached task until the gate opens. The detached task does
    /// not get the cancel of the call.
    ///
    /// - Parameter arguments: The record.
    /// - Returns: A sentence, after the gate opens.
    func call(arguments: NamedThingArguments) async throws -> String {
        await Task.detached { [gate] in await gate.waitUntilOpen() }.value
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
