import Foundation
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// A tokenizer loader that wraps the Hugging Face tokenizer loader, and records
/// the folder of each tokenizer that it loads.
///
/// A test gives it to `MLXModelLoader(tokenizerLoader:)`, and counts the loads
/// that the model loads caused.
struct RecordingTokenizerLoader: TokenizerLoader {
    /// The folder of each tokenizer load, in the order in which the loads
    /// started.
    let directories = EventLog<URL>()

    /// The loader that does the real work.
    private let upstream: any TokenizerLoader = #huggingFaceTokenizerLoader()

    /// Records `directory`, and loads its tokenizer with the Hugging Face
    /// tokenizer loader.
    ///
    /// - Parameter directory: The folder of the tokenizer files.
    /// - Returns: The loaded tokenizer.
    /// - Throws: The error of the Hugging Face tokenizer loader.
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        await directories.append(directory)
        return try await upstream.load(from: directory)
    }
}
