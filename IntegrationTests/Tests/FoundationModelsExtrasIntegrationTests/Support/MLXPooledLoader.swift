import Foundation
import FoundationModelsExtras
import HuggingFace
import MLX
import MLXEmbedders
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// A `PooledModelLoader` that loads MLX models from the Hugging Face hub.
///
/// An `.llm` key gives an `MLXLanguageModel`, which is a FoundationModels
/// `LanguageModel`. An `.embedding` key gives a ``PooledEmbedding``.
struct MLXPooledLoader: PooledModelLoader {
    /// The revision of a model reference that names no revision.
    static let defaultRevision = "main"

    /// Downloads the model of `key` when the cache does not hold it, and loads
    /// its weights.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The loaded container.
    /// - Throws: The error of the download or of the load.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try MetalLibraryBootstrap.install()
        let configuration = ModelConfiguration(id: key.ref.repo, revision: key.ref.revision ?? Self.defaultRevision)
        switch key.role {
        case .llm:
            return try await Self.loadLanguageModel(configuration)
        case .embedding:
            return try await MLXEmbedding.load(configuration)
        }
    }

    /// Removes an `MLXLanguageModel` from the model cache of MLX. An
    /// ``MLXEmbedding`` has no such cache: its weights go when the pool
    /// releases the container.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await (container as? MLXLanguageModel)?.evict()
    }

    /// Makes an `MLXLanguageModel` and loads its weights.
    private static func loadLanguageModel(_ configuration: ModelConfiguration) async throws -> MLXLanguageModel {
        let model = MLXLanguageModel(configuration: configuration, weightsLocation: { id in
            HubCache.default.repoDirectory(repo: "\(id)", kind: .model)
        }) { configuration, progress in
            try await loadModelContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration, progressHandler: progress)
        }
        try await model.preload()
        return model
    }
}

/// An MLX embedding model as a ``PooledEmbedding``.
private struct MLXEmbedding: PooledEmbedding {
    /// The loaded model and its tokenizer.
    let container: EmbedderModelContainer

    /// The length of each vector.
    let dimension: Int

    /// Loads the model of `configuration`, and finds its dimension with one
    /// embed call.
    static func load(_ configuration: ModelConfiguration) async throws -> MLXEmbedding {
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: configuration)
        let probe = try await embed(texts: ["dimension probe"], in: container)
        return MLXEmbedding(container: container, dimension: probe.first?.count ?? 0)
    }

    /// Gives one normalized vector for each text.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await Self.embed(texts: texts, in: container)
    }

    /// Pads the tokens of `texts` to one length, runs the model, and pools the
    /// output. The same steps as the embedder of the FoundationModelsRouter.
    private static func embed(texts: [String], in container: EmbedderModelContainer) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return await container.perform { context in
            let padToken = context.tokenizer.eosTokenId ?? 0
            let tokens = texts.map { context.tokenizer.encode(text: $0, addSpecialTokens: true) }
            let length = tokens.map(\.count).max() ?? 0
            let padded = stacked(tokens.map { MLXArray($0 + Array(repeating: padToken, count: length - $0.count)) })
            let output = context.model(
                padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: padded .!= padToken)
            let pooled = context.pooling(output, normalize: true, applyLayerNorm: true)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }
}
