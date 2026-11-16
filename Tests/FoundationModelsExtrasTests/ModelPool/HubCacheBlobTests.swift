import Foundation
import HuggingFace
import Testing

@testable import FoundationModelsExtras

/// The lookups of a blob of the Hugging Face cache by its etag, and the tree
/// listing of a revision as ``HubTreeMetadata``. Each test uses a temporary
/// cache and a ``HubStub``. No test uses the network.
@Suite("Hub cache blobs: the blob of an etag, and the tree metadata of a revision")
struct HubCacheBlobTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The commit of the files in the cache.
    private static let commit = "0123456789abcdef0123456789abcdef01234567"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The configuration of the model, a file that is not LFS.
    private static let config = HubStub.TreeFile(path: "config.json", size: 10, isLFS: false)

    /// The number of bytes of an interrupted download.
    private static let partialBytes = 40

    /// An etag that is not a safe file name: it holds `..`.
    private static let unsafeEtag = "etag..bin"

    @Test("the complete blob of an etag is the blob file that the cache holds")
    func completeBlobIsPresentBlob() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights])

        let blob = fixture.cache.completeBlob(repo: fixture.repo, etag: Self.weights.etag)

        #expect(blob == (try fixture.cache.blobPath(repo: fixture.repo, kind: .model, etag: Self.weights.etag)))
    }

    @Test("the complete blob of an etag is nil when the cache holds only the incomplete blob")
    func completeBlobIsNilForIncompleteBlob() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeIncomplete(Self.weights, bytes: Self.partialBytes)

        #expect(fixture.cache.completeBlob(repo: fixture.repo, etag: Self.weights.etag) == nil)
    }

    @Test("the incomplete blob of an etag is the incomplete file that the cache holds")
    func incompleteBlobIsPresentFile() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeIncomplete(Self.weights, bytes: Self.partialBytes)

        let blob = fixture.cache.incompleteBlob(repo: fixture.repo, etag: Self.weights.etag)

        #expect(
            blob == (try fixture.cache.incompleteBlobPath(repo: fixture.repo, kind: .model, etag: Self.weights.etag)))
    }

    @Test("the incomplete blob of an etag is nil when the cache holds only the complete blob")
    func incompleteBlobIsNilForCompleteBlob() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights])

        #expect(fixture.cache.incompleteBlob(repo: fixture.repo, etag: Self.weights.etag) == nil)
    }

    @Test("the complete blob of an etag that is not a safe file name is nil")
    func completeBlobIsNilForUnsafeEtag() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }

        #expect(fixture.cache.completeBlob(repo: fixture.repo, etag: Self.unsafeEtag) == nil)
    }

    @Test("the incomplete blob of an etag that is not a safe file name is nil")
    func incompleteBlobIsNilForUnsafeEtag() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }

        #expect(fixture.cache.incompleteBlob(repo: fixture.repo, etag: Self.unsafeEtag) == nil)
    }

    @Test("the tree metadata of a revision holds each file of the listing with its etag")
    func treeMetadataHoldsListedFiles() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stub = HubStub(.tree([Self.weights, Self.config]))
        let client = HubSource(cache: fixture.cache, tokenProvider: .none, session: stub.session).client()

        let metadata = try await client.treeMetadata(of: fixture.repo, revision: Self.commit)

        #expect(
            metadata.files.map { [$0.path, $0.etag] } == [
                [Self.weights.path, Self.weights.etag], [Self.config.path, Self.config.etag],
            ])
    }
}
