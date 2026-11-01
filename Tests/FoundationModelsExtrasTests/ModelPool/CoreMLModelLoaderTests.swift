import CoreML
import FixtureSupport
import Foundation
@testable import FoundationModelsExtras
import HuggingFace
import MLXLMCommon
import Synchronization
import Testing

/// The Core ML loader keeps the files of its model in order: it asks the Hub
/// for the model package and the tokenizer only, finds the package in a
/// snapshot, keeps the compiled model outside the snapshot, measures the
/// weight files, and checks the inputs of the model. The embed lock runs the
/// embed calls of one model one at a time.
///
/// Each test uses a small fake snapshot in a temporary folder, or a plain
/// value. No test downloads, compiles or loads a model.
@Suite("Core ML model loader: the files, the inputs and the lock of a model that runs on the Neural Engine")
struct CoreMLModelLoaderTests {
    /// The repository of the key that each test uses.
    private static let repository = "org/ane-model"

    /// The commit of the snapshot of the fake cache.
    private static let commit = "0123456789abcdef"

    /// The name of the model package folder of the fake snapshot.
    private static let packageName = "model-8bit.mlpackage"

    /// The bytes of the weight file of the fake package.
    private static let weightBytes = 11

    /// The bytes of the other files of the fake package, which are not weights.
    private static let manifestBytes = 3

    /// The fixed token count of the fake model.
    private static let sequenceLength = 6

    /// The pad token of the token row tests.
    private static let padToken = 0

    /// The end token of the token row tests.
    private static let endToken = 1

    /// The mark of the tokenizer loader that a test gives to a loader.
    private static let tokenizerLoaderMark = "marked"

    /// The paths of a repository that the download must fetch.
    private static let wantedPaths = [
        "model-8bit.mlpackage/Manifest.json",
        "model-8bit.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "model-8bit.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
    ]

    /// The paths of a repository that the download must not fetch.
    private static let unwantedPaths = ["convert.py", "config.py", "README.md", ".gitattributes"]

    // MARK: Download patterns

    @Test("the download patterns match each file of the package and of the tokenizer", arguments: wantedPaths)
    func patternsMatchTheWantedFiles(path: String) {
        #expect(Self.matchesAPattern(path))
    }

    @Test(
        "the download patterns match no folder of a package, because the Hub gives a 404 for a folder",
        arguments: [
            "model-8bit.mlpackage",
            "model-8bit.mlpackage/Data",
            "model-8bit.mlpackage/Data/com.apple.CoreML",
            "model-8bit.mlpackage/Data/com.apple.CoreML/weights",
        ])
    func patternsSkipTheFolders(path: String) {
        #expect(!Self.matchesAPattern(path))
    }

    @Test("the download patterns match no script and no document", arguments: unwantedPaths)
    func patternsSkipTheOtherFiles(path: String) {
        #expect(!Self.matchesAPattern(path))
    }

    // MARK: Package copy

    @Test("a copy of a package holds real files with the same bytes, where the snapshot holds links to blobs")
    func copyHoldsRealFiles() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root.appendingPathComponent("cache"))
        try Self.writeSnapshot(in: cache, ref: "main")
        let snapshot = try cache.snapshotPath(
            repo: try #require(Repo.ID(rawValue: Self.repository)), kind: .model, commitHash: Self.commit)
        let package = try CoreMLPackage.locate(in: snapshot, repository: Self.repository)
        let destination = root.appendingPathComponent("copy").appendingPathComponent(Self.packageName)

        try CoreMLPackage.copy(package, to: destination)

        let weight = destination.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let values = try weight.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        #expect(values.isSymbolicLink == false)
        #expect(values.fileSize == Self.weightBytes)
        let manifest = try destination.appendingPathComponent("Manifest.json").resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(manifest.isSymbolicLink == false)
    }

    @Test("a copy of a package replaces a folder that an earlier copy left")
    func copyReplacesAnEarlierCopy() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root.appendingPathComponent("cache"))
        try Self.writeSnapshot(in: cache, ref: "main")
        let snapshot = try cache.snapshotPath(
            repo: try #require(Repo.ID(rawValue: Self.repository)), kind: .model, commitHash: Self.commit)
        let package = try CoreMLPackage.locate(in: snapshot, repository: Self.repository)
        let destination = root.appendingPathComponent("copy").appendingPathComponent(Self.packageName)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("stale.txt"))

        try CoreMLPackage.copy(package, to: destination)

        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.txt").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Manifest.json").path))
    }

    // MARK: Tokenizer folder

    @Test("a snapshot with a tokenizer config is the folder that the tokenizer loads from")
    func tokenizerFolderIsTheSnapshotWithAConfig() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))

        let folder = try await CoreMLPackage.withTokenizerFolder(of: root) { $0 }

        #expect(folder.standardizedFileURL == root.standardizedFileURL)
    }

    @Test("a snapshot with no tokenizer config gets a temporary folder with a stand-in config, and the folder goes after the load")
    func tokenizerFolderGetsAnEmptyConfig() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"a\":1}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try Data("{\"b\":2}".utf8).write(to: root.appendingPathComponent("special_tokens_map.json"))

        let seen = try await CoreMLPackage.withTokenizerFolder(of: root) { folder in
            (
                folder: folder,
                config: try String(contentsOf: folder.appendingPathComponent("tokenizer_config.json"), encoding: .utf8),
                tokenizer: try String(contentsOf: folder.appendingPathComponent("tokenizer.json"), encoding: .utf8),
                map: try String(contentsOf: folder.appendingPathComponent("special_tokens_map.json"), encoding: .utf8)
            )
        }

        #expect(seen.folder.standardizedFileURL != root.standardizedFileURL)
        #expect(seen.config == CoreMLPackage.standInTokenizerConfig)
        #expect(seen.tokenizer == "{\"a\":1}")
        #expect(seen.map == "{\"b\":2}")
        #expect(!FileManager.default.fileExists(atPath: seen.folder.path))
    }

    @Test("the temporary tokenizer folder goes also when the load throws")
    func tokenizerFolderGoesAfterAFailure() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        let seen = Mutex<URL?>(nil)

        await #expect(throws: FakeLoadError.self) {
            try await CoreMLPackage.withTokenizerFolder(of: root) { folder -> Int in
                seen.withLock { $0 = folder }
                throw FakeLoadError()
            }
        }

        let folder = try #require(seen.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Package discovery

    @Test("a snapshot with one package gives that package, whatever its file name")
    func locateFindsTheOnePackage() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makePackage(Self.packageName, in: root)

        let package = try CoreMLPackage.locate(in: root, repository: Self.repository)

        #expect(package.lastPathComponent == Self.packageName)
    }

    @Test("a snapshot with no package throws noPackage")
    func locateThrowsWithNoPackage() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: CoreMLModelLoaderError.noPackage(repository: Self.repository)) {
            try CoreMLPackage.locate(in: root, repository: Self.repository)
        }
    }

    @Test("a snapshot with two packages throws severalPackages, with the names in order")
    func locateThrowsWithTwoPackages() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makePackage("b.mlpackage", in: root)
        try Self.makePackage("a.mlpackage", in: root)

        #expect(
            throws: CoreMLModelLoaderError.severalPackages(
                repository: Self.repository, names: ["a.mlpackage", "b.mlpackage"])
        ) {
            try CoreMLPackage.locate(in: root, repository: Self.repository)
        }
    }

    // MARK: Compiled model place

    @Test("the compiled model is in the coreml-compiled folder of the cache, by repository and commit")
    func compiledModelPlace() {
        let cache = URL(fileURLWithPath: "/cache")

        let place = CoreMLPackage.compiledModel(in: cache, repository: Self.repository, commit: Self.commit)

        #expect(place.path == "/cache/coreml-compiled/org/ane-model/\(Self.commit)/model.mlmodelc")
    }

    @Test("a new commit of a repository has a new place for its compiled model")
    func compiledModelPlaceChangesWithTheCommit() {
        let cache = URL(fileURLWithPath: "/cache")

        let first = CoreMLPackage.compiledModel(in: cache, repository: Self.repository, commit: "aaaa")
        let second = CoreMLPackage.compiledModel(in: cache, repository: Self.repository, commit: "bbbb")

        #expect(first != second)
    }

    @Test("the compiled model is outside the repository folder of the Hugging Face cache")
    func compiledModelIsOutsideTheRepositoryFolder() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        let repo = try #require(Repo.ID(rawValue: Self.repository))
        let repositoryFolder = cache.repoDirectory(repo: repo, kind: .model)

        let place = CoreMLPackage.compiledModel(in: root, repository: Self.repository, commit: Self.commit)

        #expect(!place.path.hasPrefix(repositoryFolder.path))
    }

    // MARK: Token rows

    @Test("a short row is padded on the right with the pad token and a mask of zeros")
    func shortRowIsPadded() {
        let row = Self.row(of: [5, 6, 7])

        #expect(row.ids == [5, 6, 7, 0, 0, 0])
        #expect(row.mask == [1, 1, 1, 0, 0, 0])
    }

    @Test("a row of the fixed length stays as it is")
    func exactRowStays() {
        let tokens = [5, 6, 7, 8, 9, 10]

        let row = Self.row(of: tokens)

        #expect(row.ids == tokens.map(Int32.init))
        #expect(row.mask == Array(repeating: 1, count: Self.sequenceLength))
    }

    @Test("a long row keeps its first tokens, and ends with its end token")
    func longRowKeepsTheEndToken() {
        let row = Self.row(of: [5, 6, 7, 8, 9, 10, 11, Self.endToken])

        #expect(row.ids == [5, 6, 7, 8, 9, Int32(Self.endToken)])
        #expect(row.mask == Array(repeating: 1, count: Self.sequenceLength))
    }

    @Test("a long row that does not end with the end token keeps its first tokens")
    func longRowWithNoEndTokenIsCut() {
        let row = Self.row(of: [5, 6, 7, 8, 9, 10, 11, 12])

        #expect(row.ids == [5, 6, 7, 8, 9, 10])
    }

    @Test("a long row of a tokenizer with no end token keeps its first tokens")
    func longRowWithNoKnownEndTokenIsCut() {
        let row = CoreMLTokenRow(
            tokens: [5, 6, 7, 8, 9, 10, 11, Self.endToken], length: Self.sequenceLength, padToken: Self.padToken,
            endToken: nil)

        #expect(row.ids == [5, 6, 7, 8, 9, 10])
    }

    @Test("a long row of a tokenizer with no configured end token keeps the end token that the vocabulary names")
    func longRowKeepsTheVocabularyEndToken() {
        let tokenizer = ConfiglessTokenizer(tokens: [5, 6, 7, 8, 9, 10, 11, ConfiglessTokenizer.endTokenID])

        let row = CoreMLTokenRow(text: "any", tokenizer: tokenizer, length: Self.sequenceLength)

        #expect(row.ids == [5, 6, 7, 8, 9, ConfiglessTokenizer.endTokenID].map(Int32.init))
    }

    @Test("the pad token fills a short row, also when it is not zero")
    func padTokenIsTheGivenToken() {
        let row = CoreMLTokenRow(tokens: [5], length: 3, padToken: 9, endToken: nil)

        #expect(row.ids == [5, 9, 9])
        #expect(row.mask == [1, 0, 0])
    }

    // MARK: Input contract

    @Test("a model with input_ids and attention_mask of int32[1, 128] gives the length 128 and the output embedding")
    func contractOfTheKnownModel() throws {
        let contract = try Self.contract()

        #expect(contract.sequenceLength == 128)
        #expect(contract.outputName == "embedding")
    }

    @Test("the length of the contract is the length of the inputs of the model, not a fixed number")
    func contractReadsTheLength() throws {
        let contract = try Self.contract(shape: [1, 64])

        #expect(contract.sequenceLength == 64)
    }

    @Test("a model with one output of another name uses that output")
    func contractTakesTheOnlyOutput() throws {
        let contract = try Self.contract(outputs: ["vector"])

        #expect(contract.outputName == "vector")
    }

    @Test("a model with several outputs and none named embedding is not supported")
    func contractRejectsAmbiguousOutputs() {
        #expect(throws: CoreMLModelLoaderError.self) { try Self.contract(outputs: ["a", "b"]) }
    }

    @Test("a model with no attention_mask input is not supported")
    func contractRejectsMissingMask() {
        #expect(throws: CoreMLModelLoaderError.self) {
            try CoreMLEmbeddingContract(
                inputs: [CoreMLEmbeddingContract.inputIDsName: Self.spec()],
                inputNames: [CoreMLEmbeddingContract.inputIDsName], outputNames: ["embedding"])
        }
    }

    @Test("a model with an extra input is not supported")
    func contractRejectsExtraInput() {
        #expect(throws: CoreMLModelLoaderError.self) { try Self.contract(extraInput: "token_type_ids") }
    }

    @Test("a model with float32 inputs is not supported")
    func contractRejectsFloatInputs() {
        #expect(throws: CoreMLModelLoaderError.self) { try Self.contract(dataType: .float32) }
    }

    @Test("a model with a batch of more than one row is not supported")
    func contractRejectsBatches() {
        #expect(throws: CoreMLModelLoaderError.self) { try Self.contract(shape: [4, 128]) }
    }

    @Test("a model whose two inputs differ in shape is not supported")
    func contractRejectsDifferentShapes() {
        #expect(throws: CoreMLModelLoaderError.self) {
            try CoreMLEmbeddingContract(
                inputs: [
                    CoreMLEmbeddingContract.inputIDsName: Self.spec(shape: [1, 128]),
                    CoreMLEmbeddingContract.attentionMaskName: Self.spec(shape: [1, 64]),
                ],
                inputNames: [CoreMLEmbeddingContract.inputIDsName, CoreMLEmbeddingContract.attentionMaskName],
                outputNames: ["embedding"])
        }
    }

    // MARK: The loader

    @Test("a loader keeps the tokenizer loader that its init gets")
    func loaderKeepsTheGivenTokenizerLoader() throws {
        let loader = CoreMLModelLoader(tokenizerLoader: MarkedLoader(mark: Self.tokenizerLoaderMark))

        let kept = try #require(loader.tokenizerLoader as? MarkedLoader)

        #expect(kept.mark == Self.tokenizerLoaderMark)
    }

    @Test("an LLM key throws unsupportedRole at load")
    func llmKeyIsRejectedAtLoad() async {
        let loader = CoreMLModelLoader(cache: HubCache(cacheDirectory: URL(fileURLWithPath: "/nonexistent")))

        await #expect(throws: CoreMLModelLoaderError.unsupportedRole(.llm)) {
            try await loader.load(ModelPoolKey(ref: ModelRef(Self.repository), role: .llm))
        }
    }

    @Test("an LLM key throws unsupportedRole at the footprint measure")
    func llmKeyIsRejectedAtFootprint() async {
        let loader = CoreMLModelLoader(cache: HubCache(cacheDirectory: URL(fileURLWithPath: "/nonexistent")))

        await #expect(throws: CoreMLModelLoaderError.unsupportedRole(.llm)) {
            try await loader.footprintBytes(of: ModelPoolKey(ref: ModelRef(Self.repository), role: .llm))
        }
    }

    @Test("the message of the unsupported role says that the loader handles embedding models only")
    func unsupportedRoleMessage() {
        let message = CoreMLModelLoaderError.unsupportedRole(.llm).errorDescription

        #expect(message?.contains("embedding") == true)
    }

    @Test("the footprint of a key is the size of the weight file of the package, and no other file")
    func footprintIsTheWeightFiles() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(in: cache, ref: ModelRef.defaultRevision)
        let loader = CoreMLModelLoader(cache: cache)

        let bytes = try await loader.footprintBytes(of: ModelPoolKey(ref: ModelRef(Self.repository), role: .embedding))

        #expect(bytes == Int64(Self.weightBytes))
    }

    @Test("the footprint of a key that pins a commit reads the snapshot of that commit")
    func footprintOfAPinnedCommit() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(in: cache, ref: nil)
        let loader = CoreMLModelLoader(cache: cache)
        let key = ModelPoolKey(ref: ModelRef(repo: Self.repository, revision: Self.commit), role: .embedding)

        let bytes = try await loader.footprintBytes(of: key)

        #expect(bytes == Int64(Self.weightBytes))
    }

    @Test("the footprint of a key that the cache does not hold throws notInCache")
    func footprintOfAMissingModel() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = CoreMLModelLoader(cache: HubCache(cacheDirectory: root))
        let key = ModelPoolKey(ref: ModelRef(Self.repository), role: .embedding)

        await #expect(throws: CoreMLModelLoaderError.notInCache(key: key, revision: ModelRef.defaultRevision)) {
            try await loader.footprintBytes(of: key)
        }
    }

    @Test("a loader with a cache folder downloads to that folder")
    func cacheFolderIsTheDownloadFolder() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let loader = CoreMLModelLoader(cacheDirectory: root)

        #expect(try #require(loader.hubClient().cache?.cacheDirectory) == root)
    }

    @Test("a loader with a fixed token provider gives a hub client that sends that token")
    func fixedTokenProviderGivesItsToken() async {
        let loader = CoreMLModelLoader(tokenProvider: .fixed(token: "t"))

        #expect(await loader.hubClient().bearerToken == "t")
    }

    @Test("evict releases nothing and returns")
    func evictReturns() async {
        await CoreMLModelLoader().evict(FakeModel(loaderName: "container"))
    }

    // MARK: The embed lock

    @Test("the embed lock runs the calls in the order in which they reached it, one at a time")
    func lockRunsCallsInOrder() async throws {
        let lock = CoreMLEmbedLock()
        let log = Recorder<String>()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let first = Task {
            try await lock.run {
                log.append("first starts")
                for await _ in gate {}
                log.append("first ends")
            }
        }
        // The first call holds the lock before the second call reaches it.
        while log.values.isEmpty { await Task.yield() }
        let second = Task { try await lock.run { log.append("second runs") } }
        // The second call has reached the lock, but cannot start yet.
        for _ in 0..<100 { await Task.yield() }
        let startedBeforeOpen = log.values
        open.finish()
        try await first.value
        try await second.value

        #expect(startedBeforeOpen == ["first starts"])
        #expect(log.values == ["first starts", "first ends", "second runs"])
    }

    @Test("the embed lock gives the error of a call and then runs the next call")
    func lockSurvivesAnError() async throws {
        let lock = CoreMLEmbedLock()

        await #expect(throws: FakeLoadError.self) { try await lock.run { throw FakeLoadError() } }
        let value = try await lock.run { 42 }

        #expect(value == 42)
    }

    // MARK: Helpers

    /// Whether any download pattern matches `path`, as the Hugging Face client
    /// matches: `fnmatch` with no flags.
    private static func matchesAPattern(_ path: String) -> Bool {
        CoreMLPackage.downloadPatterns.contains { fnmatch($0, path, 0) == 0 }
    }

    /// Makes the token row of `tokens` for the fake model.
    private static func row(of tokens: [Int]) -> CoreMLTokenRow {
        CoreMLTokenRow(tokens: tokens, length: sequenceLength, padToken: padToken, endToken: endToken)
    }

    /// The spec of one input of the model of the contract tests.
    private static func spec(shape: [Int] = [1, 128], dataType: MLMultiArrayDataType = .int32) -> CoreMLTensorSpec {
        CoreMLTensorSpec(shape: shape, dataType: dataType)
    }

    /// Makes the contract of a model whose two inputs have the given shape
    /// and type.
    private static func contract(
        shape: [Int] = [1, 128], dataType: MLMultiArrayDataType = .int32, outputs: [String] = ["embedding"],
        extraInput: String? = nil
    ) throws -> CoreMLEmbeddingContract {
        var names = [CoreMLEmbeddingContract.inputIDsName, CoreMLEmbeddingContract.attentionMaskName]
        var inputs = Dictionary(uniqueKeysWithValues: names.map { ($0, spec(shape: shape, dataType: dataType)) })
        if let extraInput {
            names.append(extraInput)
            inputs[extraInput] = spec(shape: shape, dataType: dataType)
        }
        return try CoreMLEmbeddingContract(inputs: inputs, inputNames: names, outputNames: outputs)
    }

    /// Makes an empty package folder `name` in `root`.
    private static func makePackage(_ name: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
    }

    /// Writes one snapshot of ``repository`` in `cache`: a model package of a
    /// manifest, a model file and a weight file, each a link to a blob, and
    /// a tokenizer file.
    ///
    /// - Parameters:
    ///   - cache: The cache to write in.
    ///   - ref: The ref file to write, which names ``commit``, or `nil` for no
    ///     ref file.
    /// - Throws: The error of a file write.
    private static func writeSnapshot(in cache: HubCache, ref: String?) throws {
        let repo = try #require(Repo.ID(rawValue: repository))
        if let ref {
            try cache.updateRef(repo: repo, kind: .model, ref: ref, commit: commit)
        }
        let blobs = cache.blobsDirectory(repo: repo, kind: .model)
        let snapshot = try cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        let files = FileManager.default
        try files.createDirectory(at: blobs, withIntermediateDirectories: true)
        let contents = [
            "\(packageName)/Manifest.json": manifestBytes,
            "\(packageName)/Data/com.apple.CoreML/model.mlmodel": manifestBytes,
            "\(packageName)/Data/com.apple.CoreML/weights/weight.bin": weightBytes,
            "tokenizer.json": manifestBytes,
        ]
        for (path, byteCount) in contents {
            let blob = blobs.appendingPathComponent("blob-\(path.replacingOccurrences(of: "/", with: "-"))")
            try Data(repeating: 0, count: byteCount).write(to: blob)
            let link = snapshot.appendingPathComponent(path)
            try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: link, withDestinationURL: blob)
        }
    }
}

/// A tokenizer loader that a test can know by its mark. It loads no tokenizer:
/// each load throws ``FakeLoadError``.
private struct MarkedLoader: TokenizerLoader {
    /// The text that tells this tokenizer loader from a different one.
    let mark: String

    /// Throws, because the test runs no load.
    ///
    /// - Parameter directory: The folder of the tokenizer. The fake does not
    ///   read it.
    /// - Returns: No tokenizer.
    /// - Throws: ``FakeLoadError`` always.
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        throw FakeLoadError()
    }
}

/// A tokenizer whose config names no end token, as the stand-in config of a
/// repository with no `tokenizer_config.json` does. Its vocabulary holds the
/// pad token and the end token of the Gemma family.
private struct ConfiglessTokenizer: MLXLMCommon.Tokenizer {
    /// The id of the pad token.
    static let padTokenID = 0

    /// The id of the end token.
    static let endTokenID = 1

    /// The tokens that every text gives.
    let tokens: [Int]

    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { tokens }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }

    func convertTokenToId(_ token: String) -> Int? {
        ["<pad>": Self.padTokenID, "<eos>": Self.endTokenID][token]
    }

    func convertIdToToken(_ id: Int) -> String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}
