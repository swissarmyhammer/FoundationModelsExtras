import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The format of the files of a model on the Hugging Face Hub. ``HubModelLoader``
/// uses ``detect(paths:)`` to pick its loader, and a caller that sizes or lists
/// repositories can use the same rule, thus the caller and the loader cannot
/// disagree.
public enum HubModelFormat: Equatable, Sendable {
    /// Safetensors weights, which ``MLXModelLoader`` loads.
    case mlx
    /// A `.mlpackage` folder, which ``CoreMLModelLoader`` loads.
    case coreML

    /// The extension of a Core ML package folder.
    private static let packageExtension = "mlpackage"

    /// The extension of a weight file of MLX.
    private static let weightFileExtension = "safetensors"

    /// Decides the format of a repository from the paths of its files.
    ///
    /// A repository is Core ML when it holds a `.mlpackage` folder and no
    /// `safetensors` file. A repository that holds both formats is MLX, because
    /// MLX loads each role. A repository that holds neither is MLX, thus the
    /// MLX loader gives the error about the missing files.
    ///
    /// Only a `.mlpackage` folder counts as Core ML. ``CoreMLModelLoader``
    /// compiles a package itself, and it does not load a compiled `.mlmodelc`
    /// folder, thus a repository with only a `.mlmodelc` folder is MLX here.
    /// A `safetensors` file at any depth makes the repository MLX.
    ///
    /// - Parameter paths: The paths of the files of the repository, relative
    ///   to its root. A folder of a package can appear as a path or as a
    ///   component of the path of a file.
    /// - Returns: The format of the repository.
    public static func detect(paths: [String]) -> HubModelFormat {
        var hasPackage = false
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            if components.contains(where: { URL(filePath: $0).pathExtension == packageExtension }) {
                hasPackage = true
            }
            if let last = components.last, URL(filePath: last).pathExtension == weightFileExtension {
                return .mlx
            }
        }
        return hasPackage ? .coreML : .mlx
    }
}

/// The loader that ``ModelPool`` uses by default: it loads a model from its
/// Hugging Face name, in the format that the repository holds. A repository
/// with `safetensors` weights loads with ``MLXModelLoader``. A repository with a
/// `.mlpackage` folder loads with ``CoreMLModelLoader``, which runs on the
/// Apple Neural Engine.
///
/// ```swift
/// let pool = ModelPool()   // loads with HubModelLoader()
/// let mlx = PooledEmbedder(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", pool: pool)
/// let ane = PooledEmbedder(ref: "erjigit17/embeddinggemma-300m-ane-coreml", pool: pool)
/// ```
///
/// An `.llm` key always loads with MLX, because Core ML loads embedding models
/// only. For an `.embedding` key, the loader decides the format in this order:
/// 1. When the reference is the path of an existing folder, the top-level names
///    of the folder decide, and the loaders load the folder with no download.
///    An empty or unreadable folder throws ``HubModelLoaderError``.
/// 2. When the cache holds the snapshot of the model, the top-level names of
///    the snapshot decide. This needs no network.
/// 3. Otherwise, the file list of the repository on the Hub decides.
///
/// Both loaders share one cache, one token provider and one `HF_ENDPOINT`.
public struct HubModelLoader: PooledModelLoader {
    /// The Hugging Face cache and the token provider of both loaders.
    private let hub: HubSource

    /// The loader of a repository with `safetensors` weights.
    private let mlx: MLXModelLoader

    /// The loader of a repository with a `.mlpackage` folder.
    private let coreML: CoreMLModelLoader

    /// Makes a loader over a Hugging Face cache. See
    /// ``MLXModelLoader/init(cacheDirectory:tokenProvider:tokenizerLoader:drafterRegistration:)``
    /// for the meaning of each parameter.
    ///
    /// ```swift
    /// let models = URL.applicationSupportDirectory.appending(path: "Models")
    /// let pool = ModelPool(loader: HubModelLoader(cacheDirectory: models))
    /// ```
    ///
    /// - Parameters:
    ///   - cacheDirectory: The folder of the cache. `nil` uses the default
    ///     Hugging Face cache.
    ///   - tokenProvider: The token provider of each download.
    ///   - tokenizerLoader: The tokenizer loader of each load. `nil` uses the
    ///     Hugging Face tokenizer loader.
    ///   - drafterRegistration: The factory that loads an MTP drafter, for the
    ///     MLX models.
    public init(
        cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment,
        tokenizerLoader: (any TokenizerLoader)? = nil, drafterRegistration: MTPDrafterRegistration = .qwen35Text
    ) {
        let cache = cacheDirectory.map { HubCache(cacheDirectory: $0) } ?? .default
        hub = HubSource(cache: cache, tokenProvider: tokenProvider)
        mlx = MLXModelLoader(
            cache: cache, tokenProvider: tokenProvider, tokenizerLoader: tokenizerLoader,
            drafterRegistration: drafterRegistration)
        coreML = CoreMLModelLoader(cache: cache, tokenProvider: tokenProvider, tokenizerLoader: tokenizerLoader)
    }

    /// Loads the model of `key` with the loader of its format. Reports
    /// nothing.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The container of the model.
    /// - Throws: The error of the format step, of the download, or of the load.
    public func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try await load(key: key) { _ in }
    }

    /// Loads the model of `key` with the loader of its format, and reports
    /// the steps of the download and the load.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets each step of the download and the load.
    /// - Returns: The container of the model.
    /// - Throws: The error of the format step, of the download, or of the load.
    public func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        switch try await format(of: key) {
        case .mlx: return try await mlx.load(key: key, progressHandler: progressHandler)
        case .coreML: return try await coreML.load(key: key, progressHandler: progressHandler)
        }
    }

    /// Releases the memory of a container. Each loader ignores a container of
    /// the other loader.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    public func evict(_ container: any Sendable) async {
        await mlx.evict(container)
        await coreML.evict(container)
    }

    /// Measures the model of `key` with the loader of its format. The pool
    /// calls this after the load, thus the cache holds the snapshot and the
    /// format needs no network.
    ///
    /// - Parameter key: A model that ``load(_:)`` loaded.
    /// - Returns: The bytes of the model.
    /// - Throws: The error of the format step or of the measure.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        switch try await format(of: key) {
        case .mlx: return try await mlx.footprintBytes(of: key)
        case .coreML: return try await coreML.footprintBytes(of: key)
        }
    }

    /// Decides the format of the model of `key`.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: ``HubModelFormat/mlx`` for an `.llm` key. For an
    ///   `.embedding` key, the format of the local folder, of the cached
    ///   snapshot, or of the files on the Hub.
    /// - Throws: ``HubModelLoaderError/unreadableLocalFolder(path:)`` for an
    ///   empty or unreadable local folder; else the error of the file list of
    ///   the Hub, when the cache holds no snapshot.
    func format(of key: ModelPoolKey) async throws -> HubModelFormat {
        guard key.role == .embedding else { return .mlx }
        let revision = key.ref.revision ?? ModelRef.defaultRevision
        let folder = hub.modelFolder(of: key.ref, revision: revision)
        let names = folder.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        guard key.ref.localDirectory == nil || !names.isEmpty else {
            throw HubModelLoaderError.unreadableLocalFolder(path: folder?.path ?? key.ref.repo)
        }
        if !names.isEmpty { return HubModelFormat.detect(paths: names) }
        guard let repo = Repo.ID(rawValue: key.ref.repo) else { return .mlx }
        let entries = try await hub.client().listFiles(in: repo, kind: .model, revision: revision, recursive: true)
        return HubModelFormat.detect(paths: entries.map(\.path))
    }
}

/// An error of ``HubModelLoader``.
public enum HubModelLoaderError: Error, Equatable, LocalizedError {
    /// The reference names the folder at `path`, and the folder is empty or
    /// cannot be read, thus its format is not known.
    case unreadableLocalFolder(path: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .unreadableLocalFolder(let path):
            return "The model folder \(path) is empty or cannot be read."
        }
    }
}
