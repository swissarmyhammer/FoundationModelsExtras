import Foundation
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// A tokenizer loader that wraps the Hugging Face tokenizer loader, and records
/// the folder of each tokenizer that it loads and each tokenizer that it gives.
///
/// A test gives it to `MLXModelLoader(tokenizerLoader:)`, and counts the loads
/// that the model loads caused. A test can also tokenize a text with the same
/// tokenizer that the loaded model uses.
struct RecordingTokenizerLoader: TokenizerLoader {
    /// The folder of each tokenizer load, in the order in which the loads
    /// started.
    let directories = EventLog<URL>()

    /// Each tokenizer that a load gave, in the order in which the loads ended.
    let tokenizers = EventLog<any MLXLMCommon.Tokenizer>()

    /// The loader that does the real work.
    private let upstream: any TokenizerLoader = #huggingFaceTokenizerLoader()

    /// Records `directory`, loads its tokenizer with the Hugging Face
    /// tokenizer loader, and records the tokenizer.
    ///
    /// - Parameter directory: The folder of the tokenizer files.
    /// - Returns: The loaded tokenizer.
    /// - Throws: The error of the Hugging Face tokenizer loader.
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        await directories.append(directory)
        let tokenizer = try await upstream.load(from: directory)
        await tokenizers.append(tokenizer)
        return tokenizer
    }
}
