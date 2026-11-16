import Foundation
import Synchronization
import Testing

@testable import FoundationModelsExtras

/// One transfer of the bytes of a file into its blob: a write that fails
/// ends the transfer and closes the blob. Each test uses a ``HubStub``, thus
/// no test uses the network.
@Suite("File transfer: a write that fails closes the blob", .timeLimit(.minutes(1)))
struct FileTransferTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The commit of the repository on the Hub.
    private static let commit = "fedcba9876543210fedcba9876543210fedcba98"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    @Test("a write that fails gives its error to the caller and closes the blob before the transfer ends")
    func failedWriteClosesBlob() async throws {
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights]))
        let writer = FailingBlobWriter()
        let transfer = FileTransfer(
            blob: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), offset: 0,
            written: { _ in }, openBlob: { _, _ in writer })
        let request = URLRequest(
            url: HubSource.host().appending(path: Self.repository).appending(path: HubStub.resolveComponent)
                .appending(path: Self.commit).appending(path: Self.weights.path))

        await #expect(throws: FailingBlobWriter.WriteError.self) {
            try await transfer.run(in: stub.session, request: request)
        }
        #expect(writer.isClosed)
    }
}

/// A blob whose each write fails, and which records its close.
private final class FailingBlobWriter: BlobWriter {
    /// The error of each write.
    struct WriteError: Error {}

    /// Whether the blob was closed.
    private let closed = Mutex(false)

    /// Whether the blob was closed.
    var isClosed: Bool {
        closed.withLock { $0 }
    }

    /// Fails.
    ///
    /// - Parameter data: The bytes to write.
    /// - Throws: ``WriteError`` each time.
    func append(_ data: Data) throws {
        throw WriteError()
    }

    /// Records the close.
    func close() throws {
        closed.withLock { $0 = true }
    }
}
