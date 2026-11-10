import Foundation
import HuggingFace
import MLX
import MLXFoundationModels
import MLXLMCommon

/// An MLX LLM gives next-token log probabilities, thus a ``PooledLogitsModel``
/// of an `.llm` key that ``MLXModelLoader`` loads works.
///
/// Each call does its model work inside `ModelContainer.perform`. That is the
/// lock of the container that each generation also takes, thus a call never
/// runs at the same time as a generation on the same model.
extension MLXLanguageModel: PooledLogits {
    /// The variable of a chat template that turns reasoning on and off.
    private static let thinkingKey = "enable_thinking"

    /// The context length of the model configuration: the
    /// `max_position_embeddings` of the `config.json` of the model, or of its
    /// `text_config`. It is `nil` when the file is not on disk or gives no
    /// context length.
    ///
    /// This property reads the file and does not load the model.
    public var maximumPromptTokens: Int? {
        modelFolder.flatMap { MLXContextLength.read(fromConfigurationIn: $0) }
    }

    /// Tokenizes text with the tokenizer of the model, with no special tokens
    /// added: no BOS token and no EOS token. Special-token text, for example
    /// `<|im_start|>`, becomes the special token.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The token IDs of the text.
    /// - Throws: The error of the load of the model.
    public func tokenize(_ text: String) async throws -> [Int] {
        try await loadContainer().perform { context in
            context.tokenizer.encode(text: text, addSpecialTokens: false)
        }
    }

    /// Renders the chat template of the tokenizer as text, with the
    /// generation prompt.
    ///
    /// The template gets `enable_thinking` set to `reasoning`. A template that
    /// does not read `enable_thinking` ignores it. The tokenizer gives the
    /// rendered chat as token IDs only, thus the text is the decode of these
    /// IDs, with the special tokens kept.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat, in order. Each message has the
    ///     keys `role` and `content` only.
    ///   - reasoning: `true` to let the model reason before it replies, `false` to turn reasoning off.
    /// - Returns: The rendered text, or `nil` if the tokenizer has no chat template.
    /// - Throws: The error of the load of the model, or of the template.
    public func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String? {
        try await loadContainer().perform { context in
            do {
                let tokens = try context.tokenizer.applyChatTemplate(
                    messages: messages, tools: nil, additionalContext: [Self.thinkingKey: reasoning])
                return context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
            } catch TokenizerError.missingChatTemplate {
                return nil
            }
        }
    }

    /// Gives the log probabilities of candidate tokens at the last position of
    /// each prompt.
    ///
    /// Each prompt is one forward pass of its own, with a new cache, and
    /// generates no token. All passes of a call run inside one lock of the
    /// container. MLX selects its matrix kernels by the count of rows in a
    /// pass, and different kernels round differently. Thus one prompt for each
    /// pass makes a call with several prompts give exactly the values of one
    /// call for each prompt. The logits of the last position go through a
    /// log-softmax over the full vocabulary in Float32, and then the candidate
    /// columns are read.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read.
    ///   - prompts: The prompts, each as token IDs.
    /// - Returns: One row for each prompt, in the order of `prompts`.
    ///   Each row has one log probability for each candidate, in the order of `candidates`.
    /// - Throws: ``MLXLogitsError/emptyPrompt(index:)`` for an empty prompt,
    ///   before the model loads; ``MLXLogitsError/tokenOutsideVocabulary(_:vocabularySize:)``
    ///   for a candidate or a prompt token outside the vocabulary; or the
    ///   error of the load of the model.
    public func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]] {
        if let index = prompts.firstIndex(where: \.isEmpty) {
            throw MLXLogitsError.emptyPrompt(index: index)
        }
        guard !candidates.isEmpty, !prompts.isEmpty else {
            return prompts.map { _ in [] }
        }
        return try await loadContainer().perform { context in
            try prompts.map { prompt in
                try MLXForwardPass.logProbabilities(of: candidates, after: prompt, in: context)
            }
        }
    }

    /// The folder that holds the `config.json` of the model: the folder of a
    /// directory configuration, or the snapshot of the revision in the Hugging
    /// Face cache that holds ``weightsLocation``. It is `nil` when the cache
    /// holds no snapshot of the revision.
    private var modelFolder: URL? {
        switch configuration.id {
        case .directory(let folder):
            return folder
        case .id(let repository, let revision):
            let cacheFolder = weightsLocation(configuration.name).deletingLastPathComponent()
            return HubSource(cache: HubCache(cacheDirectory: cacheFolder), tokenProvider: .none)
                .snapshotDirectory(of: repository, revision: revision)
        }
    }
}

/// An error of the log probabilities of an MLX LLM.
public enum MLXLogitsError: Error, Equatable, LocalizedError {
    /// The prompt at this index has no token. The model cannot give a next
    /// token with no position to read.
    case emptyPrompt(index: Int)

    /// A candidate or a prompt token is not an ID of the vocabulary of the
    /// model, which has `vocabularySize` IDs, from 0.
    case tokenOutsideVocabulary(Int, vocabularySize: Int)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .emptyPrompt(let index):
            return "The prompt at index \(index) has no token. Each prompt must have at least one token."
        case .tokenOutsideVocabulary(let id, let vocabularySize):
            return """
                The token ID \(id) is not in the vocabulary of the model. The IDs of the vocabulary are \
                0 to \(vocabularySize - 1).
                """
        }
    }
}

/// The forward pass of one prompt.
private enum MLXForwardPass {
    /// Gives the log probabilities of the candidates at the last position of
    /// one prompt, from one forward pass with a new cache.
    ///
    /// MLX builds the graph before it calculates a value, thus the size of
    /// the vocabulary is known, and each ID is checked, before the GPU runs.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read. There is at least one.
    ///   - prompt: The token IDs of the prompt. There is at least one.
    ///   - context: The model, inside the lock of its container.
    /// - Returns: One log probability for each candidate, in the order of `candidates`.
    /// - Throws: ``MLXLogitsError/tokenOutsideVocabulary(_:vocabularySize:)``
    ///   for an ID outside the vocabulary, or the error of the new cache.
    static func logProbabilities(
        of candidates: [Int], after prompt: [Int], in context: ModelContext
    ) throws -> [Double] {
        let tokens = MLXArray(prompt.map { Int32(clamping: $0) }, [1, prompt.count])
        let cache = try context.model.newCache(parameters: nil)
        let logits = context.model.nextTokenLogits(LMInput.Text(tokens: tokens), cache: cache, state: nil).logits
        let vocabularySize = logits.dim(-1)
        if let outside = (candidates + prompt).first(where: { !(0..<vocabularySize).contains($0) }) {
            throw MLXLogitsError.tokenOutsideVocabulary(outside, vocabularySize: vocabularySize)
        }
        let lastLogits = logits[0, -1, 0...].asType(.float32)
        let logProbabilities = lastLogits - lastLogits.logSumExp(axis: -1, keepDims: true)
        let columns = MLXArray(candidates.map { Int32(clamping: $0) })
        return logProbabilities.take(columns, axis: -1).asArray(Float.self).map(Double.init)
    }
}

/// The context length that the `config.json` of a model gives.
enum MLXContextLength {
    /// The name of the configuration file of a model.
    static let configurationFileName = "config.json"

    /// The fields of a `config.json` that give the context length.
    private struct Fields: Decodable {
        /// The context length of the model.
        let maxPositionEmbeddings: Int?

        /// The text part of a model that has more than one part.
        let textConfig: TextFields?
    }

    /// The fields of the `text_config` of a `config.json` that give the context length.
    private struct TextFields: Decodable {
        /// The context length of the text part of the model.
        let maxPositionEmbeddings: Int?
    }

    /// Reads the context length from the `config.json` of `folder`: its
    /// `max_position_embeddings`, else the one of its `text_config`.
    ///
    /// - Parameter folder: The folder of the model.
    /// - Returns: The context length, or `nil` when the file cannot be read or
    ///   gives no context length.
    static func read(fromConfigurationIn folder: URL) -> Int? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(configurationFileName)),
            let fields = try? decoder.decode(Fields.self, from: data)
        else { return nil }
        return fields.maxPositionEmbeddings ?? fields.textConfig?.maxPositionEmbeddings
    }
}
