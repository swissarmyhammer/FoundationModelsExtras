import Foundation
import FoundationModelsExtras
import FoundationModelsLlamaCpp
import HuggingFace

/// The GGUF loader of ``ModelPool``: it loads a GGUF model as a
/// `LlamaLanguageModel`, which runs the model through llama.cpp on Metal.
/// Give it to ``HubModelLoader``, which picks it for each GGUF model:
///
/// ```swift
/// let pool = ModelPool(loader: HubModelLoader(gguf: LlamaCppModelLoader()))
/// let model = PooledModel(ref: "unsloth/Qwen3.8-27B-GGUF/Q4_K_M", pool: pool)
/// ```
///
/// ``GGUFSource`` gives the files of the reference: it downloads only the
/// files of the model and its image projector, and it reads a local folder or
/// `.gguf` file with no download. The loader loads the one file of the model,
/// or the first shard of its split set, with the projector.
///
/// The loader handles `.llm` keys. An `.embedding` key throws
/// ``LlamaCppModelLoaderError/unsupportedRole(_:)``. A reference with a
/// drafter throws ``LlamaCppModelLoaderError/drafterNotSupported(ref:)``
/// until `LlamaLanguageModel` takes a drafter.
///
/// The module of llama.cpp needs C++ interop: each target that imports this
/// module sets `.interoperabilityMode(.Cxx)`.
public struct LlamaCppModelLoader: PooledModelLoader {
    /// The source of the files of each model.
    private let source: GGUFSource

    /// The options of each model.
    private let options: LlamaLanguageModel.Options

    /// Makes a loader over a Hugging Face cache.
    ///
    /// - Parameters:
    ///   - cacheDirectory: The folder of the cache. `nil` uses the default
    ///     Hugging Face cache. Give the cache of ``HubModelLoader``, thus both
    ///     read the same files.
    ///   - tokenProvider: The token provider of each download.
    ///   - options: The options of each model: the context size, the type of
    ///     the KV cache, and the count of live sequences.
    public init(
        cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment,
        options: LlamaLanguageModel.Options = LlamaLanguageModel.Options()
    ) {
        source = GGUFSource(cacheDirectory: cacheDirectory, tokenProvider: tokenProvider)
        self.options = options
    }

    /// Loads the model of `key`. Reports nothing.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The `LlamaLanguageModel` of the model.
    /// - Throws: As ``load(key:progressHandler:)``.
    public func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try await load(key: key) { _ in }
    }

    /// Downloads the files of the model of `key` when they are not on the
    /// disk, and makes its `LlamaLanguageModel`. The model reads the metadata
    /// of the file now, and loads the weights at the first request.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets the bytes of the download, then
    ///     ``ModelLoadProgress/loading``.
    /// - Returns: The `LlamaLanguageModel` of the model.
    /// - Throws: ``LlamaCppModelLoaderError`` for an `.embedding` key or a
    ///   drafter, the error of ``GGUFSource``, or the error of the model.
    public func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        try Self.check(key)
        let files = try await source.files(of: key.ref, progressHandler: progressHandler)
        return try LlamaLanguageModel(gguf: files.model, projector: files.projector, options: options)
    }

    /// Releases nothing now. The registry of llama.cpp holds the weights while
    /// a request uses the model, and unloads them after its idle timeout when
    /// no model of the file is left.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    public func evict(_ container: any Sendable) async {}

    /// Measures the model of `key` as the size of its files on the disk: each
    /// shard and the projector. The pool calls this after the load, thus the
    /// files are on the disk and the measure needs no network.
    ///
    /// - Parameter key: A model that ``load(_:)`` loaded.
    /// - Returns: The bytes of the files of the model.
    /// - Throws: ``LlamaCppModelLoaderError`` for an `.embedding` key or a
    ///   drafter, or the error of ``GGUFSource/cachedFiles(of:)``.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        try Self.check(key)
        return try source.cachedFiles(of: key.ref).byteCount()
    }

    /// Checks that the loader handles `key`.
    ///
    /// - Parameter key: The model and its role.
    /// - Throws: ``LlamaCppModelLoaderError`` for an `.embedding` key or a
    ///   reference with a drafter.
    private static func check(_ key: ModelPoolKey) throws {
        guard key.role == .llm else { throw LlamaCppModelLoaderError.unsupportedRole(key.role) }
        guard key.ref.drafter == nil else {
            throw LlamaCppModelLoaderError.drafterNotSupported(ref: key.ref.stringValue)
        }
    }
}

/// An error of ``LlamaCppModelLoader``.
public enum LlamaCppModelLoaderError: Error, Equatable, LocalizedError {
    /// The loader handles `.llm` keys only, and got a key of this role.
    case unsupportedRole(ModelRole)

    /// The reference names a drafter, and a GGUF model does not load one yet.
    case drafterNotSupported(ref: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .unsupportedRole(let role):
            return "LlamaCppModelLoader loads language models only, and the key has the role \(role). "
                + "A GGUF embedding model does not load yet."
        case .drafterNotSupported(let ref):
            return "The GGUF model \(ref) names a drafter, and a GGUF model does not load a drafter yet."
        }
    }
}
