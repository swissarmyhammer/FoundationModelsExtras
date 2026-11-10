import Foundation
import FoundationModelsExtras
import FoundationModelsLlamaCpp

/// A GGUF LLM gives next-token log probabilities, thus a ``PooledLogitsModel``
/// of an `.llm` key that ``LlamaCppModelLoader`` loads works.
///
/// `LlamaLanguageModel.logProbabilities(of:after:)` of FoundationModelsLlamaCpp
/// is the requirement of ``PooledLogits`` with no change. Each prompt decodes
/// alone, in an empty sequence, and the KV cache of the sequence is cleared
/// after each prompt. Thus each prompt is evaluated exactly as given, with no
/// BOS token added, and the result of a prompt does not depend on the other
/// prompts of the call. Each value is a log-softmax over the full vocabulary
/// at the last position of the prompt. The call takes the lock of the
/// generations of the model, thus a call and a generation do not run at the
/// same time.
///
/// The tokenizer and the chat template read the vocabulary of the GGUF file
/// only, thus ``tokenize(_:)`` and ``renderChatTemplate(_:reasoning:)`` load
/// no weights.
extension LlamaLanguageModel: PooledLogits {
    /// The key of the role of a message of ``renderChatTemplate(_:reasoning:)``.
    private static let roleKey = "role"

    /// The key of the text of a message of ``renderChatTemplate(_:reasoning:)``.
    private static let contentKey = "content"

    /// The context size of the model: the number of tokens that one prompt can hold.
    public var maximumPromptTokens: Int? {
        contextSize
    }

    /// Tokenizes text with the vocabulary of the model, with no special tokens
    /// added: no BOS token and no EOS token. Special-token text, for example
    /// `<|im_start|>`, becomes the special token.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The token IDs of the text.
    /// - Throws: The error of the load of the vocabulary, or of the tokenizer.
    public func tokenize(_ text: String) async throws -> [Int] {
        try tokenizer().tokens(text, parsesSpecialTokens: true).map(Int.init)
    }

    /// Renders the chat template of the model as text, with the generation
    /// prompt.
    ///
    /// When the vocabulary adds a BOS token to a prompt, the text starts with
    /// the BOS text, thus ``tokenize(_:)`` of the text gives the tokens that a
    /// generation decodes.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat, in order. Each message has the
    ///     keys `role` and `content`. The role is `"system"`, `"user"`,
    ///     `"assistant"` or `"tool"`.
    ///   - reasoning: `true` to let the model reason before it replies, `false` to turn reasoning off.
    /// - Returns: The rendered text, or `nil` if the model has no chat template.
    /// - Throws: ``LlamaLogitsError/messageWithoutKey(_:index:)`` for a
    ///   message with no `role` or no `content`; or the error of the load of
    ///   the vocabulary, or of the template, for example for a role that the
    ///   template does not know.
    public func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String? {
        let chat = try messages.enumerated().map { index, message in
            LlamaChatMessage(
                role: try Self.value(of: Self.roleKey, in: message, index: index),
                content: try Self.value(of: Self.contentKey, in: message, index: index))
        }
        return try tokenizer().renderChatTemplate(chat, reasoning: reasoning)
    }

    /// Gives the value of a key of a message.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - message: The message.
    ///   - index: The index of the message in the chat.
    /// - Returns: The value.
    /// - Throws: ``LlamaLogitsError/messageWithoutKey(_:index:)`` when the
    ///   message has no value for `key`.
    private static func value(of key: String, in message: [String: String], index: Int) throws -> String {
        guard let value = message[key] else {
            throw LlamaLogitsError.messageWithoutKey(key, index: index)
        }
        return value
    }
}

/// An error of the log-probability source of a GGUF LLM.
public enum LlamaLogitsError: Error, Equatable, LocalizedError {
    /// The message at this index of a chat has no value for this key.
    case messageWithoutKey(String, index: Int)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .messageWithoutKey(let key, let index):
            return """
                The message at index \(index) has no "\(key)" key. Each message must have the keys "role" and \
                "content".
                """
        }
    }
}
