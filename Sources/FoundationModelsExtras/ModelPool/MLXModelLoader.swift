import Foundation
import FoundationModels
import HuggingFace
import MLX
import MLXEmbedders
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The built-in loader of ``ModelPool``: it loads an MLX model from its
/// Hugging Face name, and downloads the model when the cache does not hold it.
///
/// An `.llm` key gives an `MLXLanguageModel`, which is a FoundationModels
/// `LanguageModel` with guided output, tool calls and a reasoning trace. An
/// `.embedding` key gives a ``PooledEmbedding``.
///
/// ```swift
/// let pool = ModelPool()   // loads with MLXModelLoader()
/// let hold = try await pool.acquire(ModelPoolKey(ref: "mlx-community/Qwen3-4B-4bit", role: .llm))
/// ```
public struct MLXModelLoader: PooledModelLoader {
    /// The revision of a model reference that names no revision.
    static let defaultRevision = "main"

    /// The file extension of a weight file.
    private static let weightFileExtension = "safetensors"

    /// The capabilities of each `MLXLanguageModel` that the loader makes: the
    /// capabilities that the FoundationModelsRouter declares for each LLM.
    private static let languageModelCapabilities: [LanguageModelCapabilities.Capability] = [
        .guidedGeneration, .toolCalling, .reasoning,
    ]

    /// The Hugging Face cache that holds the downloaded weights.
    private let cache: HubCache

    /// The tokenizer loader of each load, of an LLM and of an embedding model.
    let tokenizerLoader: any TokenizerLoader

    /// Makes a loader over the default Hugging Face cache, the cache that the
    /// download writes to.
    ///
    /// - Parameter tokenizerLoader: The tokenizer loader of each load, of an
    ///   LLM and of an embedding model. For example, a loader that gives a
    ///   chat template with a pinned date. `nil` uses the Hugging Face
    ///   tokenizer loader.
    public init(tokenizerLoader: (any TokenizerLoader)? = nil) {
        self.init(cache: .default, tokenizerLoader: tokenizerLoader)
    }

    /// Makes a loader that measures the weights in `cache`.
    ///
    /// - Parameters:
    ///   - cache: The Hugging Face cache that holds the weights.
    ///   - tokenizerLoader: The tokenizer loader of each load. `nil` uses the
    ///     Hugging Face tokenizer loader.
    init(cache: HubCache, tokenizerLoader: (any TokenizerLoader)? = nil) {
        self.cache = cache
        self.tokenizerLoader = tokenizerLoader ?? #huggingFaceTokenizerLoader()
    }

    /// Downloads the model of `key` when the cache does not hold it, and loads
    /// its weights. Reports nothing.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: An `MLXLanguageModel` for an `.llm` key, or a
    ///   ``PooledEmbedding`` for an `.embedding` key.
    /// - Throws: The error of the metal library step, of the download, or of
    ///   the load.
    public func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try await load(key: key) { _ in }
    }

    /// Downloads the model of `key` when the cache does not hold it, and loads
    /// its weights. Reports the completed bytes and the total bytes of the
    /// files of the repository that the Hugging Face downloader gives, then
    /// ``ModelLoadProgress/loading`` when the download returns. A model that
    /// the model cache of MLX holds already loads with no download and no
    /// report.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets each step of the download and the load.
    /// - Returns: An `MLXLanguageModel` for an `.llm` key, or a
    ///   ``PooledEmbedding`` for an `.embedding` key.
    /// - Throws: The error of the metal library step, of the download, or of
    ///   the load.
    public func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        try MetalLibraryBootstrap.install()
        let configuration = ModelConfiguration(id: key.ref.repo, revision: Self.revision(of: key))
        let downloader = ProgressReportingDownloader(upstream: #hubDownloader(), report: progressHandler)
        switch key.role {
        case .llm:
            return try await Self.loadLanguageModel(
                configuration: configuration, downloader: downloader, tokenizerLoader: tokenizerLoader)
        case .embedding:
            return try await MLXEmbedding.load(
                configuration: configuration, downloader: downloader, tokenizerLoader: tokenizerLoader)
        }
    }

    /// Removes an `MLXLanguageModel` from the model cache of MLX. An
    /// embedding model has no such cache: its weights go when the pool
    /// releases the container.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    public func evict(_ container: any Sendable) async {
        await (container as? MLXLanguageModel)?.evict()
    }

    /// Measures the weight files of `key` in the Hugging Face cache, at the
    /// revision that ``load(_:)`` loads. A loaded model keeps each tensor of
    /// these files as one MLX array, thus this is about the memory of the
    /// model.
    ///
    /// - Parameter key: A model that ``load(_:)`` loaded.
    /// - Returns: The sum of the sizes of the weight files.
    /// - Throws: ``MLXModelLoaderError`` when the cache does not hold the
    ///   model, or the error of a file read.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        let snapshot = try snapshotDirectory(of: key)
        let files = try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == Self.weightFileExtension }.reduce(0) { total, file in
            total + (try Self.blobBytes(of: file))
        }
    }

    /// The revision of `key` that the loader loads.
    private static func revision(of key: ModelPoolKey) -> String {
        key.ref.revision ?? defaultRevision
    }

    /// Finds the snapshot folder of `key` in the cache. The revision is a ref,
    /// such as `main`, that a ref file names, or a commit.
    ///
    /// - Parameter key: The model.
    /// - Returns: The snapshot folder.
    /// - Throws: ``MLXModelLoaderError`` when the cache does not hold the
    ///   revision of the model.
    private func snapshotDirectory(of key: ModelPoolKey) throws -> URL {
        let revision = Self.revision(of: key)
        guard let repo = Repo.ID(rawValue: key.ref.repo) else {
            throw MLXModelLoaderError.notInCache(key: key, revision: revision)
        }
        let commit = cache.resolveRevision(repo: repo, kind: .model, ref: revision) ?? revision
        let snapshot = try cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        guard FileManager.default.fileExists(atPath: snapshot.path) else {
            throw MLXModelLoaderError.notInCache(key: key, revision: revision)
        }
        return snapshot
    }

    /// The size of the blob that a snapshot file links to.
    ///
    /// - Parameter file: A file of a snapshot.
    /// - Returns: The size of the blob.
    /// - Throws: The error of the read of the file size.
    private static func blobBytes(of file: URL) throws -> Int64 {
        let blob = file.resolvingSymlinksInPath()
        guard let size = try blob.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw MLXModelLoaderError.unknownFileSize(path: blob.path)
        }
        return Int64(size)
    }

    /// Makes an `MLXLanguageModel` with ``languageModelCapabilities`` and
    /// loads its weights.
    ///
    /// - Parameters:
    ///   - configuration: The model and its revision.
    ///   - downloader: The downloader of the files of the model.
    ///   - tokenizerLoader: The loader of the tokenizer of the model.
    /// - Returns: The loaded model.
    /// - Throws: The error of the download or of the load.
    private static func loadLanguageModel(
        configuration: ModelConfiguration, downloader: ProgressReportingDownloader,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> MLXLanguageModel {
        let model = MLXLanguageModel(
            configuration: configuration, capabilities: languageModelCapabilities,
            weightsLocation: { id in HubCache.default.repoDirectory(repo: "\(id)", kind: .model) }
        ) { configuration, progress in
            try await loadModelContainer(
                from: downloader, using: tokenizerLoader,
                configuration: configuration, progressHandler: progress)
        }
        try await model.preload()
        return model
    }
}

/// An error of ``MLXModelLoader``.
public enum MLXModelLoaderError: Error, Equatable, LocalizedError {
    /// The Hugging Face cache holds no snapshot of `revision` of the model of
    /// `key`.
    case notInCache(key: ModelPoolKey, revision: String)
    /// The file system gave no size for the weight file at `path`.
    case unknownFileSize(path: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .notInCache(let key, let revision):
            return "The Hugging Face cache holds no \(revision) revision of \(key.ref.stringValue)."
        case .unknownFileSize(let path):
            return "The file system gave no size for the weight file \(path)."
        }
    }
}

/// An MLX embedding model as a ``PooledEmbedding``.
private struct MLXEmbedding: PooledEmbedding {
    /// The token that pads a short text when the tokenizer has no end token.
    private static let fallbackPadToken = 0

    /// The loaded model and its tokenizer.
    let container: EmbedderModelContainer

    /// Loads the model of `configuration`.
    ///
    /// - Parameters:
    ///   - configuration: The model and its revision.
    ///   - downloader: The downloader of the files of the model.
    ///   - tokenizerLoader: The loader of the tokenizer of the model.
    /// - Returns: The loaded model.
    /// - Throws: The error of the download or of the load.
    static func load(
        configuration: ModelConfiguration, downloader: ProgressReportingDownloader,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> MLXEmbedding {
        MLXEmbedding(
            container: try await EmbedderModelFactory.shared.loadContainer(
                from: downloader, using: tokenizerLoader, configuration: configuration))
    }

    /// Gives one normalized vector for each text. This pads the tokens of
    /// `texts` to one length, runs the model, and pools the output. The mask of
    /// each row comes from its length, and the model and the pooling both get
    /// it. Thus a pad token changes no vector, and the end token of a text,
    /// which can equal the pad token, stays in its vector.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One normalized vector for each text, in the order of `texts`.
    func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return await container.perform { context in
            let padding = EmbeddingBatchPadding(
                rows: texts.map { context.tokenizer.encode(text: $0, addSpecialTokens: true) },
                padToken: context.tokenizer.eosTokenId ?? Self.fallbackPadToken)
            let tokens = stacked(padding.tokens.map { MLXArray($0) })
            let mask = stacked(padding.mask.map { MLXArray($0) })
            let output = context.model(
                tokens, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: tokens), attentionMask: mask)
            let pooled = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: true)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }
}
