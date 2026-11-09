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
/// The drafter of the reference, on the Hub or local, is a GGUF model too:
/// ``GGUFSource`` gives its files the same way, and the model drafts with its
/// one file or first shard. A drafter that holds no GGUF model throws
/// ``LlamaCppModelLoaderError/drafterNotGGUF(ref:)``. A model with MTP layers
/// drafts with no drafter: llama.cpp reads them from the file of the model.
/// ``LlamaLanguageModel/Options/speculativeDecoding`` of the options turns
/// both off.
///
/// The loader handles `.llm` keys. An `.embedding` key throws
/// ``LlamaCppModelLoaderError/unsupportedRole(_:)``.
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

    /// Downloads the files of the model of `key` and of its drafter when they
    /// are not on the disk, and makes its `LlamaLanguageModel`. The model reads the metadata
    /// of the file now, and loads the weights at the first request.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets the bytes of the download of the drafter,
    ///     then of the model, then ``ModelLoadProgress/loading``.
    /// - Returns: The `LlamaLanguageModel` of the model.
    /// - Throws: ``LlamaCppModelLoaderError`` for an `.embedding` key or a
    ///   drafter that is not GGUF, the error of ``GGUFSource``, or the error
    ///   of the model.
    public func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        try Self.check(key)
        let drafter = try await Self.drafterFiles(of: key.ref) { drafter in
            try await source.files(of: drafter) { progress in
                if progress != .loading { progressHandler(progress) }
            }
        }
        let files = try await source.files(of: key.ref, progressHandler: progressHandler)
        return try LlamaLanguageModel(
            gguf: files.model, projector: files.projector, drafter: drafter?.model, options: options)
    }

    /// Releases nothing now. The registry of llama.cpp holds the weights while
    /// a request uses the model, and unloads them after its idle timeout when
    /// no model of the file is left.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    public func evict(_ container: any Sendable) async {}

    /// Measures the model of `key` with the estimate of llama.cpp:
    /// `LlamaLanguageModel.footprintBytes` over each shard, the projector and
    /// the drafter, with the KV cache and the context of the options. The
    /// estimate reads the headers of the files on the disk, and the pool
    /// calls this after the load, thus it needs no network. It reads no
    /// weights.
    ///
    /// - Parameter key: A model that ``load(_:)`` loaded.
    /// - Returns: The estimate, in bytes.
    /// - Throws: ``LlamaCppModelLoaderError`` for an `.embedding` key or a
    ///   drafter that is not GGUF, the error of
    ///   ``GGUFSource/cachedFiles(of:)`` when a file is not on the disk, or
    ///   the error of the estimate.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        try Self.check(key)
        let drafter = try await Self.drafterFiles(of: key.ref) { try source.cachedFiles(of: $0) }
        let files = try source.cachedFiles(of: key.ref)
        return Int64(
            try LlamaLanguageModel.footprintBytes(
                gguf: files.model, projector: files.projector, drafter: drafter?.model, options: options))
    }

    /// Checks that the loader handles `key`.
    ///
    /// - Parameter key: The model and its role.
    /// - Throws: ``LlamaCppModelLoaderError/unsupportedRole(_:)`` for an
    ///   `.embedding` key.
    private static func check(_ key: ModelPoolKey) throws {
        guard key.role == .llm else { throw LlamaCppModelLoaderError.unsupportedRole(key.role) }
    }

    /// The files of the drafter of `ref`, from `files`.
    ///
    /// - Parameters:
    ///   - ref: The reference of the model.
    ///   - files: Gives the files of a GGUF reference.
    /// - Returns: The files of the drafter, or `nil` when `ref` names none.
    /// - Throws: ``LlamaCppModelLoaderError/drafterNotGGUF(ref:)`` when the
    ///   drafter holds no GGUF model, or the error of `files`.
    private static func drafterFiles(
        of ref: ModelRef, _ files: (ModelRef) async throws -> GGUFModelFiles
    ) async throws -> GGUFModelFiles? {
        guard let drafter = ref.drafter else { return nil }
        do {
            return try await files(drafter)
        } catch GGUFSelectionError.noModel {
            throw LlamaCppModelLoaderError.drafterNotGGUF(ref: drafter.stringValue)
        }
    }
}

/// An error of ``LlamaCppModelLoader``.
public enum LlamaCppModelLoaderError: Error, Equatable, LocalizedError {
    /// The loader handles `.llm` keys only, and got a key of this role.
    case unsupportedRole(ModelRole)

    /// The model is GGUF, and its drafter `ref` holds no GGUF model.
    case drafterNotGGUF(ref: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .unsupportedRole(let role):
            return "LlamaCppModelLoader loads language models only, and the key has the role \(role). "
                + "A GGUF embedding model does not load yet."
        case .drafterNotGGUF(let ref):
            return "The drafter \(ref) of a GGUF model holds no GGUF model. "
                + "A GGUF model drafts with a GGUF drafter only."
        }
    }
}
