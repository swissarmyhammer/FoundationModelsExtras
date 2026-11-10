import FixtureSupport
import Foundation
import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import FoundationModelsLlamaCpp
import LlamaCppTestFixtures
import Testing

/// The parts of the ``PooledLogits`` conformance of `LlamaLanguageModel` that
/// need no weights: the tokenizer, the chat template, the prompt limit, and
/// the check of each message.
///
/// Each test uses the vocab-only Qwen3.5 GGUF file and the Qwen3.5 chat
/// template of `LlamaCppTestFixtures`. The initializer of the model reads the
/// metadata only, and the tokenizer reads the vocabulary only, thus no test
/// loads weights or uses the network.
@Suite("LlamaCpp logits: the tokenizer, the chat template and the prompt limit")
struct LlamaLogitsTests {
    /// The vocab-only GGUF file of the tests.
    private static let vocabulary = "qwen35"

    /// The chat template of the tests.
    private static let template = "Qwen3.5-4B"

    /// The generation prompt of ``template`` with reasoning off.
    private static let generationPromptWithNoReasoning = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    /// The generation prompt of ``template`` with reasoning on.
    private static let generationPromptWithReasoning = "<|im_start|>assistant\n<think>\n"

    /// A context that is not the default of the options.
    private static let contextSize = 8192

    /// A plain text with no special-token text.
    private static let text = "The quick brown fox jumps over the lazy dog."

    /// A user message of a chat.
    private static let userMessage = ["role": "user", "content": "Answer A or B."]

    /// Makes a model of the vocab-only GGUF file, with the chat template of
    /// the tests.
    ///
    /// - Parameter contextSize: The context size of the model.
    /// - Returns: The model.
    /// - Throws: The error of a fixture or of the initializer.
    private static func makeModel(contextSize: Int = contextSize) throws -> LlamaLanguageModel {
        let template = try String(contentsOf: LlamaCppTestFixtures.templateURL(named: Self.template), encoding: .utf8)
        return try LlamaLanguageModel(
            gguf: LlamaCppTestFixtures.vocabURL(named: vocabulary).resolvingSymlinksInPath(),
            options: LlamaLanguageModel.Options(contextSize: contextSize),
            chatTemplate: template)
    }

    @Test("the special-token text <|im_start|> tokenizes to one token")
    func specialTokenTextIsOneToken() async throws {
        let model = try Self.makeModel()

        #expect(try await model.tokenize("<|im_start|>").count == 1)
    }

    @Test("a plain text tokenizes to the tokens of the tokenizer, with no BOS token")
    func plainTextHasTheTokensOfTheTokenizer() async throws {
        let model = try Self.makeModel()
        let expected = try model.tokenizer().tokens(Self.text, parsesSpecialTokens: true).map(Int.init)

        let tokens = try await model.tokenize(Self.text)

        #expect(!tokens.isEmpty)
        #expect(tokens == expected)
    }

    @Test("the chat template with reasoning off ends with the generation prompt")
    func chatTemplateWithNoReasoningEndsWithTheGenerationPrompt() async throws {
        let model = try Self.makeModel()

        let rendered = try #require(try await model.renderChatTemplate([Self.userMessage], reasoning: false))

        #expect(rendered.contains("Answer A or B."))
        #expect(rendered.hasSuffix(Self.generationPromptWithNoReasoning))
    }

    @Test("the chat template with reasoning on ends with the open think block")
    func chatTemplateWithReasoningEndsWithTheOpenThinkBlock() async throws {
        let model = try Self.makeModel()

        let rendered = try #require(try await model.renderChatTemplate([Self.userMessage], reasoning: true))

        #expect(rendered.hasSuffix(Self.generationPromptWithReasoning))
    }

    @Test("a message with no role throws, and names the index and the key")
    func messageWithNoRoleThrows() async throws {
        let model = try Self.makeModel()

        await #expect(throws: LlamaLogitsError.messageWithoutKey("role", index: 1)) {
            try await model.renderChatTemplate([Self.userMessage, ["content": "No role."]], reasoning: false)
        }
    }

    @Test("a message with no content throws, and names the index and the key")
    func messageWithNoContentThrows() async throws {
        let model = try Self.makeModel()

        await #expect(throws: LlamaLogitsError.messageWithoutKey("content", index: 0)) {
            try await model.renderChatTemplate([["role": "user"]], reasoning: false)
        }
    }

    @Test("the error of a message with no key tells the key and the index")
    func messageWithoutKeyDescription() {
        let description = LlamaLogitsError.messageWithoutKey("role", index: 1).errorDescription

        #expect(
            description
                == """
                The message at index 1 has no "role" key. Each message must have the keys "role" and "content".
                """)
    }

    @Test("the prompt limit is the context size of the model")
    func promptLimitIsTheContextSize() throws {
        let model = try Self.makeModel()

        #expect(model.maximumPromptTokens == Self.contextSize)
        #expect(model.maximumPromptTokens == model.contextSize)
    }

    @Test("a PooledLogitsModel of a GGUF file tokenizes through the pool")
    func pooledLogitsModelTokenizesThroughThePool() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        try FileManager.default.copyItem(
            at: LlamaCppTestFixtures.vocabURL(named: Self.vocabulary).resolvingSymlinksInPath(), to: file)
        let loader = HubModelLoader(cacheDirectory: root, gguf: LlamaCppModelLoader(cacheDirectory: root))
        let pool = ModelPool(loader: loader)
        let model = PooledLogitsModel(ref: ModelRef(file.path), pool: pool)

        let tokens = try await model.tokenize("<|im_start|>")

        #expect(tokens.count == 1)
        #expect(model.maximumPromptTokens == LlamaLanguageModel.Options().contextSize)
    }
}
