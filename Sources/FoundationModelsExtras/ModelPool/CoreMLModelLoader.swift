import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// A loader of ``ModelPool`` for Core ML embedding models: it loads a model
/// that runs on the Apple Neural Engine from its Hugging Face name, and
/// downloads the model when the cache does not hold it.
///
/// The loader handles `.embedding` keys. An `.llm` key throws
/// ``CoreMLModelLoaderError/unsupportedRole(_:)``. The container of a key is a
/// ``PooledEmbedding``, thus ``PooledEmbedder`` embeds with it.
///
/// ```swift
/// let pool = ModelPool(loader: CoreMLModelLoader())
/// let embedder = PooledEmbedder(ref: "erjigit17/embeddinggemma-300m-ane-coreml", pool: pool)
/// let vectors = try await embedder.embed(texts: ["task: search result | query: save my work"])
/// ```
///
/// The repository must hold one `.mlpackage` folder and a `tokenizer.json`.
/// The package takes the inputs `input_ids` and `attention_mask`, each an
/// `int32` array of the shape `[1, length]`, and gives one vector. The length
/// comes from the model, and the loader cuts a longer text and pads a shorter
/// one to it. The model does the pooling and the normalizing.
///
/// The loader adds no prefix to a text. A model that expects a prefix needs it
/// from the caller. For `erjigit17/embeddinggemma-300m-ane-coreml`, a query
/// starts with `task: search result | query: ` and a document starts with
/// `title: none | text: `. The weights of that model have the Gemma license.
///
/// A local reference (one that starts with `/`, `~` or `.`) to an existing
/// folder loads from that folder, with no download. The folder must hold one `.mlpackage` folder and a
/// `tokenizer.json`, as a repository does. The compiled model of such a folder is
/// kept by the path and by the size and the time of the last change of each file
/// of the package, thus a package that changes in place compiles again.
///
/// The first load of a commit compiles the package, which takes some time.
/// The loader keeps the compiled model in the folder `coreml-compiled` of the
/// cache folder, by repository and commit, and each later load reads it.
public struct CoreMLModelLoader: PooledModelLoader {
    /// The Hugging Face cache that holds the downloaded files, and the token
    /// provider of each download.
    private let hub: HubSource

    /// The tokenizer loader of each load.
    let tokenizerLoader: any TokenizerLoader

    /// Makes a loader over a Hugging Face cache. The download writes to this
    /// cache, the load reads the files from it, and the compiled models go in
    /// a folder of it.
    ///
    /// ```swift
    /// let models = URL.applicationSupportDirectory.appending(path: "Models")
    /// let pool = ModelPool(loader: CoreMLModelLoader(cacheDirectory: models))
    /// ```
    ///
    /// - Parameters:
    ///   - cacheDirectory: The folder of the cache. A given folder is the
    ///     cache, also when `HF_HUB_CACHE` or `HF_HOME` names a different
    ///     folder. `nil` uses the default Hugging Face cache, which reads
    ///     these variables.
    ///   - tokenProvider: The token provider of each download, a
    ///     `TokenProvider` of swift-huggingface. The default `.environment`
    ///     reads `HF_TOKEN` and `~/.cache/huggingface/token`. A host with its
    ///     own home gives `.custom { ... }`, or `.none`, which sends no token.
    ///   - tokenizerLoader: The tokenizer loader of each load. `nil` uses the
    ///     Hugging Face tokenizer loader.
    public init(
        cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment,
        tokenizerLoader: (any TokenizerLoader)? = nil
    ) {
        self.init(
            cache: cacheDirectory.map { HubCache(cacheDirectory: $0) } ?? .default, tokenProvider: tokenProvider,
            tokenizerLoader: tokenizerLoader)
    }

    /// Makes a loader over `cache`.
    ///
    /// - Parameters:
    ///   - cache: The Hugging Face cache that the download writes to.
    ///   - tokenProvider: The token provider of each download.
    ///   - tokenizerLoader: The tokenizer loader of each load. `nil` uses the
    ///     Hugging Face tokenizer loader.
    init(cache: HubCache, tokenProvider: TokenProvider = .environment, tokenizerLoader: (any TokenizerLoader)? = nil) {
        hub = HubSource(cache: cache, tokenProvider: tokenProvider)
        self.tokenizerLoader = tokenizerLoader ?? #huggingFaceTokenizerLoader()
    }

    /// Downloads the model of `key` when the cache does not hold it, and loads
    /// it. Reports nothing.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: A ``PooledEmbedding``.
    /// - Throws: ``CoreMLModelLoaderError`` for an `.llm` key or a repository
    ///   with no usable package, or the error of the download or the load.
    public func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try await load(key: key) { _ in }
    }

    /// Downloads the model of `key` when the cache does not hold it, and loads
    /// it. Reports the completed bytes and the total bytes of the files that
    /// the Hugging Face downloader gives, then ``ModelLoadProgress/loading``
    /// when the download returns.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets each step of the download and the load.
    /// - Returns: A ``PooledEmbedding``.
    /// - Throws: ``CoreMLModelLoaderError`` for an `.llm` key or a repository
    ///   with no usable package, or the error of the download or the load.
    public func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        guard key.role == .embedding else { throw CoreMLModelLoaderError.unsupportedRole(key.role) }
        let downloader = ProgressReportingDownloader(upstream: #hubDownloader(hubClient()), report: progressHandler)
        return try await ModelLoadTelemetry.tracePhase(ExtrasTelemetry.SpanName.modelLoadWeights) { _ in
            let snapshot: URL
            if let folder = key.ref.localDirectory {
                snapshot = folder
            } else {
                snapshot = try await downloader.download(
                    id: key.ref.repo, revision: Self.revision(of: key), matching: CoreMLPackage.downloadPatterns,
                    useLatest: false) { _ in }
            }
            return try await CoreMLEmbedding.load(
                ref: key.ref, snapshot: snapshot, cacheDirectory: hub.cache.cacheDirectory,
                tokenizerLoader: tokenizerLoader)
        }
    }

    /// Releases nothing. A Core ML model has no cache beside its container:
    /// its memory goes when the pool drops the container. The compiled model
    /// stays in the cache folder for the next load.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    public func evict(_ container: any Sendable) async {}

    /// Measures the weight files of the model package of `key` in the Hugging
    /// Face cache, at the revision that ``load(_:)`` loads.
    ///
    /// - Parameter key: A model that ``load(_:)`` loaded.
    /// - Returns: The sum of the sizes of the weight files of the package.
    /// - Throws: ``CoreMLModelLoaderError`` for an `.llm` key, when the cache
    ///   does not hold the model, or when it holds no usable package; or the
    ///   error of a file read.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        guard key.role == .embedding else { throw CoreMLModelLoaderError.unsupportedRole(key.role) }
        let revision = Self.revision(of: key)
        guard let snapshot = hub.modelFolder(of: key.ref, revision: revision)
        else { throw CoreMLModelLoaderError.notInCache(key: key, revision: revision) }
        let package = try CoreMLPackage.locate(in: snapshot, repository: key.ref.repo)
        return try CoreMLPackage.weightFiles(in: package).reduce(0) { total, file in
            guard let size = try HubSource.blobBytes(of: file) else {
                throw CoreMLModelLoaderError.unknownFileSize(path: file.resolvingSymlinksInPath().path)
            }
            return total + size
        }
    }

    /// The Hugging Face client of each download, over the cache and the token
    /// provider of the loader.
    ///
    /// - Returns: A client at the host of `HF_ENDPOINT` or the Hugging Face Hub.
    func hubClient() -> HubClient {
        hub.client()
    }

    /// The revision of `key` that the loader loads.
    private static func revision(of key: ModelPoolKey) -> String {
        key.ref.revision ?? ModelRef.defaultRevision
    }
}

/// An error of ``CoreMLModelLoader``.
public enum CoreMLModelLoaderError: Error, Equatable, LocalizedError {
    /// The loader handles `.embedding` keys only, and got a key of this role.
    case unsupportedRole(ModelRole)
    /// The Hugging Face cache holds no snapshot of `revision` of the model of
    /// `key`.
    case notInCache(key: ModelPoolKey, revision: String)
    /// The file system gave no size for the weight file at `path`.
    case unknownFileSize(path: String)
    /// The snapshot of `repository` holds no `.mlpackage` folder.
    case noPackage(repository: String)
    /// The snapshot of `repository` holds more than one `.mlpackage` folder,
    /// and the loader does not choose between them.
    case severalPackages(repository: String, names: [String])
    /// The model does not fit the embedding contract, for `reason`.
    case unsupportedModel(reason: String)
    /// The file system could not read the package folder at `path` or a file
    /// in it, thus the loader cannot tell if the package changed.
    case unreadablePackage(path: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .unsupportedRole(let role):
            return "CoreMLModelLoader loads embedding models only, and the key has the role \(role)."
        case .notInCache(let key, let revision):
            return "The Hugging Face cache holds no \(revision) revision of \(key.ref.stringValue)."
        case .unknownFileSize(let path):
            return "The file system gave no size for the weight file \(path)."
        case .noPackage(let repository):
            return "The snapshot of \(repository) holds no .mlpackage folder."
        case .severalPackages(let repository, let names):
            return "The snapshot of \(repository) holds more than one .mlpackage folder: \(names.joined(separator: ", "))."
        case .unsupportedModel(let reason):
            return "The Core ML model is not an embedding model that this loader can run: \(reason)."
        case .unreadablePackage(let path):
            return "The file system could not read the model package \(path)."
        }
    }
}
