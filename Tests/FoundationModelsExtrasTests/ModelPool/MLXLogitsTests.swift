import FixtureSupport
import Foundation
@testable import FoundationModelsExtras
import HuggingFace
import MLXFoundationModels
import MLXLMCommon
import Testing

/// The parts of the ``PooledLogits`` conformance of `MLXLanguageModel` that
/// need no weights: the prompt limit from the `config.json` of the model, and
/// the checks that run before the model loads.
///
/// Each model of a test has a loader that throws, thus no test loads a model.
/// Each prompt-limit test writes a `config.json` in a temporary directory: a
/// model folder, or a snapshot in the layout of the Hugging Face hub.
@Suite("MLX logits: the prompt limit and the checks before the load")
struct MLXLogitsTests {
    /// The context length that the `config.json` of a test gives.
    private static let contextLength = 40_960

    /// The repository of the Hub model of a test.
    private static let repository = "org/logits-model"

    /// The commit that the ref file of the default revision names.
    private static let commit = "0123456789abcdef"

    /// The ref of the default revision.
    private static let mainRef = "main"

    /// The error of the loader of each test model.
    private struct LoadNotExpected: Error {}

    /// Makes a model whose loader throws ``LoadNotExpected``.
    ///
    /// - Parameters:
    ///   - configuration: The configuration of the model.
    ///   - weightsLocation: The folder of the weights of the model.
    /// - Returns: The model.
    private static func model(
        _ configuration: ModelConfiguration, weightsLocation: URL = FileManager.default.temporaryDirectory
    ) -> MLXLanguageModel {
        MLXLanguageModel(configuration: configuration, weightsLocation: { _ in weightsLocation }) { _, _ in
            throw LoadNotExpected()
        }
    }

    /// Writes `json` as the `config.json` of `folder`.
    ///
    /// - Parameters:
    ///   - json: The text of the file.
    ///   - folder: The folder of the file.
    /// - Throws: The error of the write.
    private static func writeConfiguration(_ json: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("config.json"))
    }

    /// Gives the prompt limit of a model folder that holds `json` as its `config.json`.
    ///
    /// - Parameter json: The text of the file.
    /// - Returns: The prompt limit of the model.
    /// - Throws: The error of the write.
    private static func promptLimit(ofConfiguration json: String) throws -> Int? {
        let folder = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeConfiguration(json, in: folder)
        return model(ModelConfiguration(directory: folder)).maximumPromptTokens
    }

    @Test("the prompt limit is the max_position_embeddings of the config.json of the folder")
    func promptLimitIsTheTopLevelContextLength() throws {
        #expect(try Self.promptLimit(ofConfiguration: #"{"max_position_embeddings": \#(Self.contextLength)}"#)
            == Self.contextLength)
    }

    @Test("the prompt limit is the max_position_embeddings of text_config when the top level has none")
    func promptLimitIsTheTextContextLength() throws {
        let json = #"{"text_config": {"max_position_embeddings": \#(Self.contextLength)}}"#

        #expect(try Self.promptLimit(ofConfiguration: json) == Self.contextLength)
    }

    @Test("the prompt limit is nil when the config.json gives no context length")
    func promptLimitIsNilWithNoContextLength() throws {
        #expect(try Self.promptLimit(ofConfiguration: #"{"vocab_size": 10}"#) == nil)
    }

    @Test("the prompt limit is nil when the folder has no config.json")
    func promptLimitIsNilWithNoConfiguration() throws {
        let folder = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(Self.model(ModelConfiguration(directory: folder)).maximumPromptTokens == nil)
    }

    @Test("the prompt limit of a Hub model comes from its snapshot in the cache of its weights location")
    func promptLimitOfAHubModelReadsItsSnapshot() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        let repo = try #require(Repo.ID(rawValue: Self.repository))
        try cache.updateRef(repo: repo, kind: .model, ref: Self.mainRef, commit: Self.commit)
        let snapshot = try cache.snapshotPath(repo: repo, kind: .model, commitHash: Self.commit)
        try Self.writeConfiguration(#"{"max_position_embeddings": \#(Self.contextLength)}"#, in: snapshot)
        let configuration = ModelConfiguration(id: Self.repository, revision: Self.mainRef)

        let model = Self.model(configuration, weightsLocation: cache.repoDirectory(repo: repo, kind: .model))

        #expect(model.maximumPromptTokens == Self.contextLength)
    }

    @Test("an empty prompt throws before the model loads")
    func emptyPromptThrows() async {
        let model = Self.model(ModelConfiguration(id: Self.repository))

        await #expect(throws: MLXLogitsError.emptyPrompt(index: 1)) {
            try await model.logProbabilities(of: [0], after: [[1], []])
        }
    }

    @Test("no candidates give one empty row for each prompt, with no load")
    func noCandidatesGiveEmptyRows() async throws {
        let model = Self.model(ModelConfiguration(id: Self.repository))

        #expect(try await model.logProbabilities(of: [], after: [[1], [2, 3]]) == [[], []])
    }

    @Test("no prompts give no rows, with no load")
    func noPromptsGiveNoRows() async throws {
        let model = Self.model(ModelConfiguration(id: Self.repository))

        #expect(try await model.logProbabilities(of: [0], after: []).isEmpty)
    }
}
