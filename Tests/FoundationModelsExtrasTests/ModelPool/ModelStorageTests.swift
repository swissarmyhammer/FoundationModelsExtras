import Foundation
import HuggingFace
import Testing

@testable import FoundationModelsExtras

/// ``ModelStorage``: the download size and the disk state of a model. Each
/// test uses a temporary Hugging Face cache and a ``HubStub`` transport. No
/// test uses the network, downloads a file or loads a model.
@Suite("Model storage: the download size and the disk state of a model, with no download")
struct ModelStorageTests {
    /// The repository of the MLX model of the tests.
    private static let repository = "org/model"

    /// The repository of the GGUF model of the tests.
    private static let ggufRepository = "org/model-GGUF"

    /// The commit of the cached snapshots.
    private static let commit = "0123456789abcdef0123456789abcdef01234567"

    /// The weights of the MLX model.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The configuration of the MLX model.
    private static let config = HubStub.TreeFile(path: "config.json", size: 10, isLFS: false)

    /// A file that the MLX download does not fetch.
    private static let readme = HubStub.TreeFile(path: "README.md", size: 5, isLFS: false)

    /// The first shard of a split MLX model.
    private static let firstShard = HubStub.TreeFile(path: "model-00001-of-00002.safetensors", size: 100, isLFS: true)

    /// The second shard of a split MLX model.
    private static let secondShard = HubStub.TreeFile(path: "model-00002-of-00002.safetensors", size: 100, isLFS: true)

    /// The bytes of the second shard that an interrupted download wrote.
    private static let incompleteBytes = 30

    /// The files of the GGUF repository: two quantizations and a projector.
    private static let ggufFiles = [
        HubStub.TreeFile(path: "Q4_K_M/model-Q4_K_M.gguf", size: 40, isLFS: true),
        HubStub.TreeFile(path: "Q8_0/model-Q8_0.gguf", size: 80, isLFS: true),
        HubStub.TreeFile(path: "mmproj-F16.gguf", size: 7, isLFS: true),
    ]

    /// The MLX model of the tests.
    private static let ref = ModelRef(repository)

    // MARK: - The disk state

    @Test("a model whose snapshot holds each file of the download is complete")
    func completeModel() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config, Self.readme])))
            .storageInfo(of: Self.ref)

        #expect(info.state == .complete)
    }

    @Test("the file set is the files that the MLX download fetches")
    func mlxFileSet() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config, Self.readme])))
            .storageInfo(of: Self.ref)

        #expect(info.files == ["config.json", "model.safetensors"])
    }

    @Test("the total bytes are the sum of the sizes of the file set on the Hub")
    func totalBytes() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config, Self.readme])))
            .storageInfo(of: Self.ref)

        #expect(info.totalBytes == Int64(Self.weights.size + Self.config.size))
    }

    @Test("the present bytes of a complete model are the bytes of its blobs")
    func presentBytesOfACompleteModel() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config])))
            .storageInfo(of: Self.ref)

        #expect(info.presentBytes == Int64(Self.weights.size + Self.config.size))
    }

    @Test("the disk bytes are the bytes that the blobs use on the disk")
    func diskBytes() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config])))
            .storageInfo(of: Self.ref)

        #expect(info.diskBytes == (try fixture.allocatedBytes(of: [Self.weights, Self.config])))
    }

    @Test("the revision is the commit that the ref file of the cache names")
    func resolvedRevision() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config])))
            .storageInfo(of: Self.ref)

        #expect(info.revision == Self.commit)
    }

    @Test("a model with an incomplete blob and a missing shard is partial, with the present and the total bytes")
    func partialModel() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.config, Self.firstShard])
        try fixture.writeIncomplete(Self.secondShard, bytes: Self.incompleteBytes)
        let tree = [Self.config, Self.firstShard, Self.secondShard]

        let info = try await fixture.storage(HubStub(.tree(tree))).storageInfo(of: Self.ref)

        let present = Int64(Self.config.size + Self.firstShard.size + Self.incompleteBytes)
        let total = Int64(tree.map(\.size).reduce(0, +))
        #expect(info.state == .partial(presentBytes: present, totalBytes: total))
    }

    @Test("a model with a missing shard and no incomplete blob is partial")
    func missingShardIsPartial() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.config, Self.firstShard])
        let tree = [Self.config, Self.firstShard, Self.secondShard]

        let info = try await fixture.storage(HubStub(.tree(tree))).storageInfo(of: Self.ref)

        let present = Int64(Self.config.size + Self.firstShard.size)
        let total = Int64(tree.map(\.size).reduce(0, +))
        #expect(info.state == .partial(presentBytes: present, totalBytes: total))
    }

    @Test("a model with no file in the cache is missing")
    func missingModel() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config])))
            .storageInfo(of: Self.ref)

        #expect(info.state == .missing)
    }

    @Test("a model with no file in the cache has no present bytes and no revision")
    func missingModelHasNoBytes() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }

        let info = try await fixture.storage(HubStub(.tree([Self.weights, Self.config])))
            .storageInfo(of: Self.ref)

        #expect(info.presentBytes == 0 && info.diskBytes == 0 && info.revision == nil)
    }

    // MARK: - Local and GGUF references

    @Test("a local folder is complete, and its size is the size of its files")
    func localFolder() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("local-model", isDirectory: true)
        try HubFixture.write([Self.weights, Self.config], in: folder)
        let stub = HubStub(.offline)

        let info = try await fixture.storage(stub).storageInfo(of: ModelRef(folder.path))

        let size = Int64(Self.weights.size + Self.config.size)
        #expect(info.state == .complete && info.totalBytes == size && info.presentBytes == size)
        #expect(stub.requests.isEmpty)
    }

    @Test("a local location that does not exist fails, and names the location")
    func missingLocalLocation() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let location = fixture.root.appendingPathComponent("no-such-model").path

        await #expect(throws: HubModelLoaderError.missingLocalModel(path: location)) {
            try await fixture.storage(HubStub(.offline)).storageInfo(of: ModelRef(location))
        }
    }

    @Test("a GGUF quantization ref counts its own file and the projector, not the other quantizations")
    func ggufQuantization() async throws {
        let fixture = try HubFixture(repository: Self.ggufRepository, commit: Self.commit)
        defer { fixture.remove() }

        let info = try await fixture.storage(HubStub(.tree(Self.ggufFiles)))
            .storageInfo(of: ModelRef("\(Self.ggufRepository)/Q4_K_M"))

        #expect(info.files == ["Q4_K_M/model-Q4_K_M.gguf", "mmproj-F16.gguf"])
        #expect(info.totalBytes == Int64(Self.ggufFiles[0].size + Self.ggufFiles[2].size))
    }

    @Test("a GGUF quantization whose file is in the snapshot is complete")
    func ggufQuantizationComplete() async throws {
        let fixture = try HubFixture(repository: Self.ggufRepository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.ggufFiles[0], Self.ggufFiles[2]])

        let info = try await fixture.storage(HubStub(.tree(Self.ggufFiles)))
            .storageInfo(of: ModelRef("\(Self.ggufRepository)/Q4_K_M"))

        #expect(info.state == .complete)
    }

    @Test("a ref with a path to MLX files fails, because only a GGUF model loads from a path")
    func pathToMLXFails() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let ref = ModelRef("\(Self.repository)/sub")
        let tree = [HubStub.TreeFile(path: "sub/model.safetensors", size: 1, isLFS: true)]

        await #expect(throws: HubModelLoaderError.pathNeedsGGUF(ref: ref.stringValue)) {
            try await fixture.storage(HubStub(.tree(tree))).storageInfo(of: ref)
        }
    }

    // MARK: - The network and the metadata cache

    @Test("a call makes one request: the tree listing of the revision")
    func oneTreeRequest() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stub = HubStub(.tree([Self.weights, Self.config]))

        _ = try await fixture.storage(stub).storageInfo(of: Self.ref)

        #expect(stub.requests.map(\.path) == ["/api/models/\(Self.repository)/tree/main"])
    }

    @Test("a second call reads the cached metadata and makes no request")
    func secondCallMakesNoRequest() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        _ = try await fixture.storage(HubStub(.tree([Self.weights, Self.config]))).storageInfo(of: Self.ref)
        let second = HubStub(.tree([Self.weights, Self.config]))

        _ = try await fixture.storage(second).storageInfo(of: Self.ref)

        #expect(second.requests.isEmpty)
    }

    @Test("an offline call uses the cached metadata")
    func offlineWithCachedMetadata() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        _ = try await fixture.storage(HubStub(.tree([Self.weights, Self.config]))).storageInfo(of: Self.ref)

        let info = try await fixture.storage(HubStub(.offline)).storageInfo(of: Self.ref)

        #expect(info.totalBytes == Int64(Self.weights.size + Self.config.size))
    }

    @Test("an offline call with no cached metadata has no total, and a complete snapshot is complete")
    func offlineWithNoMetadataAndASnapshot() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])

        let info = try await fixture.storage(HubStub(.offline)).storageInfo(of: Self.ref)

        #expect(info.totalBytes == nil && info.state == .complete)
        #expect(info.presentBytes == Int64(Self.weights.size + Self.config.size))
    }

    @Test("an offline call with no cached metadata and no snapshot is missing, with no total")
    func offlineWithNothing() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }

        let info = try await fixture.storage(HubStub(.offline)).storageInfo(of: Self.ref)

        #expect(info.totalBytes == nil && info.state == .missing && info.files.isEmpty)
    }

    @Test("an offline call with no cached metadata and a split GGUF set with a missing shard is partial")
    func offlineMissingGGUFShard() async throws {
        let fixture = try HubFixture(repository: Self.ggufRepository, commit: Self.commit)
        defer { fixture.remove() }
        let first = HubStub.TreeFile(path: "Q8_0/model-00001-of-00002.gguf", size: 50, isLFS: true)
        try fixture.writeComplete([first])

        let info = try await fixture.storage(HubStub(.offline))
            .storageInfo(of: ModelRef("\(Self.ggufRepository)/Q8_0"))

        #expect(info.state == .partial(presentBytes: Int64(first.size), totalBytes: nil))
    }

    // MARK: - The list and the value

    @Test("the list form gives one info for each ref, in the order of the refs")
    func listKeepsTheOrder() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("local-model", isDirectory: true)
        try HubFixture.write([Self.config], in: folder)
        let refs = [ModelRef(folder.path), Self.ref]

        let infos = try await fixture.storage(HubStub(.tree([Self.weights, Self.config]))).storageInfo(of: refs)

        #expect(infos.map(\.ref) == refs)
    }

    @Test("an info encodes and decodes to the same value")
    func infoRoundTrips() throws {
        let info = ModelStorageInfo(
            ref: Self.ref, revision: Self.commit, files: ["a"], totalBytes: 9, presentBytes: 3, diskBytes: 4096,
            state: .partial(presentBytes: 3, totalBytes: 9))

        let decoded = try JSONDecoder().decode(ModelStorageInfo.self, from: JSONEncoder().encode(info))

        #expect(decoded == info)
    }
}
