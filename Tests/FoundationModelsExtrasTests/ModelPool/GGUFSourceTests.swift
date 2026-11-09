import FixtureSupport
import Foundation
import HuggingFace
import Testing

@testable import FoundationModelsExtras

/// ``GGUFSource``: the files of a GGUF model on the disk, from a local
/// reference or from the cache. No test uses the network, and no test loads a
/// model.
@Suite("GGUF source: the files of a GGUF model on the disk")
struct GGUFSourceTests {
    /// The repository of the cached snapshots.
    private static let repository = "org/some-model-GGUF"

    /// The commit of the cached snapshots.
    private static let commit = "0123456789abcdef"

    /// The bytes of each fake file.
    private static let fileBytes = 16

    @Test("a local GGUF file is the model, with the projector beside it")
    func localFile() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(["model.gguf", "mmproj-F16.gguf"], in: root)
        let model = root.appendingPathComponent("model.gguf")

        let files = try await GGUFSource(cacheDirectory: root).files(of: ModelRef(model.path)) { _ in }

        #expect(files.model.path == model.path)
        #expect(files.shards.map(\.path) == [model.path])
        #expect(files.projector?.lastPathComponent == "mmproj-F16.gguf")
    }

    @Test("a local folder gives the first shard of its split set and reports the load")
    func localFolder() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Q8_0", isDirectory: true)
        try Self.write(["m-00001-of-00002.gguf", "m-00002-of-00002.gguf"], in: folder)
        let reports = ProgressLog()

        let files = try await GGUFSource(cacheDirectory: root).files(of: ModelRef(folder.path)) { reports.record($0) }

        #expect(files.model.lastPathComponent == "m-00001-of-00002.gguf")
        #expect(files.shards.map(\.lastPathComponent) == ["m-00001-of-00002.gguf", "m-00002-of-00002.gguf"])
        #expect(reports.reports == [.loading])
    }

    @Test("a cached snapshot gives the files under the path of the reference, with no network")
    func cachedSnapshot() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(in: root, paths: ["Q4_K_M/model-Q4_K_M.gguf", "Q8_0/model-Q8_0.gguf", "mmproj-F16.gguf"])
        let ref = ModelRef("\(Self.repository)/Q4_K_M")

        let source = GGUFSource(cacheDirectory: root)
        let files = try await source.files(of: ref) { _ in }
        let cached = try source.cachedFiles(of: ref)

        #expect(files.model.lastPathComponent == "model-Q4_K_M.gguf")
        #expect(files.projector?.lastPathComponent == "mmproj-F16.gguf")
        #expect(cached == files)
    }

    @Test("the cached files of a model that the cache lacks fail")
    func cachedFilesOfAMissingModel() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = ModelRef("\(Self.repository)/Q4_K_M")

        #expect(throws: GGUFSourceError.notInCache(ref: ref.stringValue)) {
            try GGUFSource(cacheDirectory: root).cachedFiles(of: ref)
        }
    }

    @Test("the byte count is the sum of the blobs of each shard and the projector")
    func byteCount() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(
            in: root, paths: ["Q8_0/m-00001-of-00002.gguf", "Q8_0/m-00002-of-00002.gguf", "Q8_0/mmproj-F16.gguf"])

        let files = try GGUFSource(cacheDirectory: root).cachedFiles(of: ModelRef("\(Self.repository)/Q8_0"))

        #expect(try files.byteCount() == Int64(3 * Self.fileBytes))
    }

    // MARK: Helpers

    /// Writes one file of ``fileBytes`` bytes for each name in `folder`.
    private static func write(_ names: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try Data(count: fileBytes).write(to: folder.appendingPathComponent(name))
        }
    }

    /// Writes one snapshot of ``repository`` at `main` in the cache in `root`,
    /// with one blob of ``fileBytes`` bytes for each path.
    private static func writeSnapshot(in root: URL, paths: [String]) throws {
        let cache = HubCache(cacheDirectory: root)
        let repo = try #require(Repo.ID(rawValue: repository))
        try cache.updateRef(repo: repo, kind: .model, ref: ModelRef.defaultRevision, commit: commit)
        let blobs = cache.blobsDirectory(repo: repo, kind: .model)
        let snapshot = try cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for path in paths {
            let blob = blobs.appendingPathComponent("blob-\(path.replacingOccurrences(of: "/", with: "-"))")
            try Data(count: fileBytes).write(to: blob)
            let link = snapshot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        }
    }

    /// The reports of one load, in order.
    private final class ProgressLog: @unchecked Sendable {
        /// The lock of the reports.
        private let lock = NSLock()

        /// The reports.
        private var log: [ModelLoadProgress] = []

        /// The reports, in order.
        var reports: [ModelLoadProgress] { lock.withLock { log } }

        /// Records one report.
        func record(_ progress: ModelLoadProgress) {
            lock.withLock { log.append(progress) }
        }
    }
}
