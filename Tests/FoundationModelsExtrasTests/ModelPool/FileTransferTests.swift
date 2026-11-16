import Foundation
import Synchronization
import TelemetryTestSupport
import Testing

@testable import FoundationModelsExtras

/// One transfer of the bytes of a file into its blob: a write that fails
/// ends the transfer and closes the blob, and a blob that does not close
/// gives its error to the caller or to a log record. Each test uses a
/// ``HubStub``, thus no test uses the network.
@Suite("File transfer: the blob closes, and no close error is lost", .timeLimit(.minutes(1)))
struct FileTransferTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The commit of the repository on the Hub.
    private static let commit = "fedcba9876543210fedcba9876543210fedcba98"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The bytes that the request sends before it stalls.
    private static let bytesBeforeStall = 30

    @Test("a write that fails gives its error to the caller and closes the blob before the transfer ends")
    func failedWriteClosesBlob() async throws {
        let writer = StubBlobWriter(writeFails: true)

        await #expect(throws: StubBlobWriter.WriteError.self) {
            try await Self.transfer(
                into: writer, stub: HubStub(.repository(commit: Self.commit, files: [Self.weights])))
        }
        #expect(writer.isClosed)
    }

    @Test("a blob that does not close after a write that fails writes one record with the error type of the close")
    func failedWriteLogsCloseFailure() async throws {
        let writer = StubBlobWriter(writeFails: true, closeFails: true)

        let records = try await TelemetryCapture.run(forbidding: []) { context in
            await #expect(throws: StubBlobWriter.WriteError.self) {
                try await Self.transfer(
                    into: writer, stub: HubStub(.repository(commit: Self.commit, files: [Self.weights])))
            }
            return context.logRecords.filter { $0.label == ExtrasTelemetry.logLabel }
        }

        #expect(records == [Self.closeFailureRecord])
    }

    @Test("a transfer that the caller cancels gives the error of the task, also when the blob does not close")
    func cancelledTransferGivesTaskError() async throws {
        let writer = StubBlobWriter(closeFails: true)

        let error = await #expect(throws: URLError.self) {
            try await Self.cancelledTransfer(into: writer)
        }

        #expect(error?.code == .cancelled)
    }

    @Test("a transfer that the caller cancels writes one record with the error type of the close that failed")
    func cancelledTransferLogsCloseFailure() async throws {
        let writer = StubBlobWriter(closeFails: true)

        let records = try await TelemetryCapture.run(forbidding: []) { context in
            await #expect(throws: URLError.self) { try await Self.cancelledTransfer(into: writer) }
            return context.logRecords.filter { $0.label == ExtrasTelemetry.logLabel }
        }

        #expect(records == [Self.closeFailureRecord])
    }

    /// The record of a blob that did not close: the error type of the close.
    private static var closeFailureRecord: TelemetryCapture.LogRecord {
        TelemetryCapture.LogRecord(
            level: .warning,
            message: "\(ExtrasTelemetry.PoolLogMessage.blobCloseFailed)",
            metadata: [
                ExtrasTelemetry.LogMetadataKey.errorType: .string(
                    ExtrasTelemetry.errorType(of: StubBlobWriter.CloseError()))
            ],
            label: ExtrasTelemetry.logLabel
        )
    }

    /// The request of the weights.
    private static var request: URLRequest {
        URLRequest(
            url: HubSource.host().appending(path: repository).appending(path: ResumableFileDownload.resolveComponent)
                .appending(path: commit).appending(path: weights.path))
    }

    /// Transfers the weights from `stub` into `writer`.
    ///
    /// - Parameters:
    ///   - writer: The blob of the transfer.
    ///   - stub: The transport.
    /// - Throws: The error of the transfer.
    private static func transfer(into writer: StubBlobWriter, stub: HubStub) async throws {
        let transfer = FileTransfer(
            blob: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), offset: 0,
            written: { stub.recordWritten($0) }, openBlob: { _, _ in writer })
        try await transfer.run(in: stub.session, request: request)
    }

    /// Starts a transfer of the weights into `writer` whose request stalls,
    /// and cancels its task when the transfer wrote each byte that the
    /// request sent.
    ///
    /// - Parameter writer: The blob of the transfer.
    /// - Throws: The error of the transfer.
    private static func cancelledTransfer(into writer: StubBlobWriter) async throws {
        let stub = HubStub(.repository(commit: commit, files: [weights], stalls: [bytesBeforeStall]))
        let transfer = Task { try await Self.transfer(into: writer, stub: stub) }
        try await stub.waitForStall(number: 1)
        transfer.cancel()
        try await transfer.value
    }
}

/// A blob whose writes and whose close can fail, and which records its
/// close.
private final class StubBlobWriter: BlobWriter {
    /// The error of a write that fails.
    struct WriteError: Error {}

    /// The error of a close that fails.
    struct CloseError: Error {}

    /// Whether each write fails.
    private let writeFails: Bool

    /// Whether the close fails.
    private let closeFails: Bool

    /// Whether the blob was closed.
    private let closed = Mutex(false)

    /// Makes a blob.
    ///
    /// - Parameters:
    ///   - writeFails: Whether each write fails.
    ///   - closeFails: Whether the close fails.
    init(writeFails: Bool = false, closeFails: Bool = false) {
        self.writeFails = writeFails
        self.closeFails = closeFails
    }

    /// Whether the blob was closed.
    var isClosed: Bool {
        closed.withLock { $0 }
    }

    /// Keeps no byte, or fails.
    ///
    /// - Parameter data: The bytes to write.
    /// - Throws: ``WriteError`` when each write fails.
    func append(_ data: Data) throws {
        guard !writeFails else { throw WriteError() }
    }

    /// Records the close, and fails when the close fails.
    ///
    /// - Throws: ``CloseError`` when the close fails.
    func close() throws {
        closed.withLock { $0 = true }
        guard !closeFails else { throw CloseError() }
    }
}
