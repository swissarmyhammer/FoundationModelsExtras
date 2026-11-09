import Foundation
import Synchronization
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
    /// GGUF files, which the GGUF loader of ``HubModelLoader`` loads. See
    /// ``GGUFFileSet`` for the files of one model.
    case gguf

    /// The extension of a Core ML package folder.
    private static let packageExtension = "mlpackage"

    /// The extension of a weight file of MLX.
    private static let weightFileExtension = "safetensors"

    /// Decides the format of a repository from the paths of its files.
    ///
    /// A repository with a `safetensors` file is MLX. Else a repository with a
    /// GGUF model file is GGUF: a shard of a split set is a model file, and
    /// an `mmproj*.gguf` projector alone is not a model. Else a repository
    /// with a `.mlpackage` folder is Core ML. A repository that holds none of
    /// these is MLX, thus the MLX loader gives the error about the missing
    /// files. MLX wins over Core ML because MLX loads each role.
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
        var hasGGUF = false
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            if components.contains(where: { URL(filePath: $0).pathExtension == packageExtension }) {
                hasPackage = true
            }
            if let last = components.last, URL(filePath: last).pathExtension == weightFileExtension {
                return .mlx
            }
            if GGUFFileSet.isModelFile(path) {
                hasGGUF = true
            }
        }
        if hasGGUF { return .gguf }
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
/// A repository with GGUF files loads with the GGUF loader that the caller
/// gives, for example `LlamaCppModelLoader` of the product
/// `FoundationModelsExtrasLlamaCpp`. That loader is a parameter, because its
/// product needs C++ interop, and a consumer with no GGUF models does not.
///
/// The files under the path of the reference decide the format, in this order:
/// 1. When the reference is local, the files of its folder decide, and the
///    loaders load the folder with no download. A `.gguf` file is GGUF. An
///    empty or unreadable folder, or a location that does not exist, throws
///    ``HubModelLoaderError``.
/// 2. When the cache holds files of the model under the path, those files
///    decide. This needs no network.
/// 3. Otherwise, the file list of the repository on the Hub decides.
///
/// An `.llm` key of a Core ML repository loads with MLX, because Core ML loads
/// embedding models only. Only a GGUF model loads from a path inside a
/// repository.
///
/// Each loader shares one cache, one token provider and one `HF_ENDPOINT`.
public struct HubModelLoader: PooledModelLoader {
    /// The Hugging Face cache and the token provider of both loaders.
    private let hub: HubSource

    /// The loader of a repository with `safetensors` weights.
    private let mlx: MLXModelLoader

    /// The loader of a repository with a `.mlpackage` folder.
    private let coreML: CoreMLModelLoader

    /// The loader of a repository with GGUF files, or `nil` when the caller
    /// gave none.
    private let gguf: (any PooledModelLoader)?

    /// The format of each model that ``poolKey(for:)`` decided, by its key
    /// with no context.
    private let formats = FormatCache()

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
    ///   - gguf: The loader of a GGUF model, such as `LlamaCppModelLoader`.
    ///     `nil`, the default, makes the load of a GGUF model throw
    ///     ``HubModelLoaderError/noGGUFLoader``.
    public init(
        cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment,
        tokenizerLoader: (any TokenizerLoader)? = nil, drafterRegistration: MTPDrafterRegistration = .qwen35Text,
        gguf: (any PooledModelLoader)? = nil
    ) {
        let cache = cacheDirectory.map { HubCache(cacheDirectory: $0) } ?? .default
        hub = HubSource(cache: cache, tokenProvider: tokenProvider)
        mlx = MLXModelLoader(
            cache: cache, tokenProvider: tokenProvider, tokenizerLoader: tokenizerLoader,
            drafterRegistration: drafterRegistration)
        coreML = CoreMLModelLoader(cache: cache, tokenProvider: tokenProvider, tokenizerLoader: tokenizerLoader)
        self.gguf = gguf
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
        case .gguf: return try await ggufLoader().load(key: key, progressHandler: progressHandler)
        }
    }

    /// Releases the memory of a container. Each loader ignores a container of
    /// the other loader.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    public func evict(_ container: any Sendable) async {
        await mlx.evict(container)
        await coreML.evict(container)
        await gguf?.evict(container)
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
        case .gguf: return try await ggufLoader().footprintBytes(of: key)
        }
    }

    /// The key of the model of `key` in the pool. A GGUF model loads at a
    /// fixed context, thus the GGUF loader gives its key, with the context.
    /// Each other format drops the context.
    ///
    /// A key with no context is the key, and needs no format. The format of
    /// each model is decided one time, and kept for each later key of the
    /// model. When the format step fails, the key stays as it is, and the
    /// load throws the error, so the progress of the load reports it.
    ///
    /// - Parameter key: The key of a request.
    /// - Returns: The key of the model in the pool.
    /// - Throws: The error of the pool key of the GGUF loader.
    public func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey {
        guard key.contextSize != nil else { return key }
        let model = key.withoutContext
        let format: HubModelFormat
        if let cached = formats[model] {
            format = cached
        } else {
            guard let detected = try? await self.format(of: model) else { return key }
            formats[model] = detected
            format = detected
        }
        guard format == .gguf, let gguf else { return model }
        return try await gguf.poolKey(for: key)
    }

    /// The GGUF loader that the caller gave.
    ///
    /// - Returns: The loader.
    /// - Throws: ``HubModelLoaderError/noGGUFLoader`` when the caller gave
    ///   none.
    private func ggufLoader() throws -> any PooledModelLoader {
        guard let gguf else { throw HubModelLoaderError.noGGUFLoader }
        return gguf
    }

    /// Decides the format of the model of `key` from the files under the path
    /// of its reference.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The format of the local location, of the cached files, or of
    ///   the files on the Hub. A Core ML model of an `.llm` key is
    ///   ``HubModelFormat/mlx``.
    /// - Throws: ``HubModelLoaderError`` for a local location that does not
    ///   exist or is an empty or unreadable folder, and for a path to a model
    ///   that is not GGUF; else the error of the file list of the Hub, when the
    ///   cache holds no files under the path.
    func format(of key: ModelPoolKey) async throws -> HubModelFormat {
        let format = HubModelFormat.detect(paths: try await paths(of: key.ref))
        guard format == .gguf || key.ref.path == nil else {
            throw HubModelLoaderError.pathNeedsGGUF(ref: key.ref.stringValue)
        }
        return key.role == .llm && format == .coreML ? .mlx : format
    }

    /// The paths of the files of the model of `ref`, relative to the root of
    /// its folder or repository, under the path of the reference.
    ///
    /// - Parameter ref: The reference of the model.
    /// - Returns: The paths: of the local folder, a local `.gguf` file, the
    ///   cached snapshot, or the file list of the Hub.
    /// - Throws: As ``format(of:)``.
    private func paths(of ref: ModelRef) async throws -> [String] {
        if ref.isLocal {
            guard let location = ref.localLocation else { throw HubModelLoaderError.missingLocalModel(path: ref.repo) }
            guard location.hasDirectoryPath else { return [location.lastPathComponent] }
            let names = HubSource.relativePaths(in: location)
            guard !names.isEmpty else { throw HubModelLoaderError.unreadableLocalFolder(path: location.path) }
            return names
        }
        let revision = ref.revision ?? ModelRef.defaultRevision
        let cached = hub.snapshotDirectory(of: ref.repo, revision: revision)
            .map { HubSource.paths(HubSource.relativePaths(in: $0), under: ref.path) } ?? []
        if !cached.isEmpty { return cached }
        guard let repo = Repo.ID(rawValue: ref.repo) else { return [] }
        let entries = try await hub.client().listFiles(in: repo, kind: .model, revision: revision, recursive: true)
        return HubSource.paths(entries.map(\.path), under: ref.path)
    }
}

/// The format of each model that ``HubModelLoader/poolKey(for:)`` decided,
/// under one lock. The copies of one loader share it.
private final class FormatCache: Sendable {
    /// The format of each model, by its key with no context.
    private let formats = Mutex<[ModelPoolKey: HubModelFormat]>([:])

    /// The format of the model of `key`, or `nil` before it is decided.
    subscript(key: ModelPoolKey) -> HubModelFormat? {
        get { formats.withLock { $0[key] } }
        set { formats.withLock { $0[key] = newValue } }
    }
}

/// An error of ``HubModelLoader``.
public enum HubModelLoaderError: Error, Equatable, LocalizedError {
    /// The reference names the folder at `path`, and the folder is empty or
    /// cannot be read, thus its format is not known.
    case unreadableLocalFolder(path: String)

    /// The reference is local, and its location is not an existing folder or
    /// `.gguf` file.
    case missingLocalModel(path: String)

    /// The reference names a path inside a repository, and the files under it
    /// are not GGUF. Only a GGUF model loads from a path.
    case pathNeedsGGUF(ref: String)

    /// The model is GGUF, and the loader has no GGUF loader.
    case noGGUFLoader

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .unreadableLocalFolder(let path):
            return "The model folder \(path) is empty or cannot be read."
        case .missingLocalModel(let path):
            return "The model \(path) is not a folder or a .gguf file on the disk."
        case .pathNeedsGGUF(let ref):
            return "The model \(ref) names a path inside its repository, and the files there are not GGUF. "
                + "Only a GGUF model loads from a path."
        case .noGGUFLoader:
            return "The model is GGUF, and this loader has no GGUF loader. "
                + "Give HubModelLoader(gguf:) the LlamaCppModelLoader of FoundationModelsExtrasLlamaCpp."
        }
    }
}
