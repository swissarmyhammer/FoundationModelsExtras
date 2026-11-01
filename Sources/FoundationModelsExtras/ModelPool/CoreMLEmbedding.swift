import CoreML
import Foundation
import MLXLMCommon

/// A first-in, first-out lock for the embed calls of one Core ML model. An
/// embed call starts only after each earlier call ended, in the order in which
/// the calls reached the lock.
actor CoreMLEmbedLock {
    /// The chain of the calls that wait for the lock or hold it.
    private var chain = SerialAsyncChain()

    /// Runs `work` after each earlier call of this lock ended.
    ///
    /// - Parameter work: The call.
    /// - Returns: The value of `work`.
    /// - Throws: `CancellationError` when the task is cancelled before it
    ///   reaches the lock, or the error of `work`.
    func run<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            _ = chain.enqueue {
                do {
                    continuation.resume(returning: try await work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// A Core ML embedding model as a ``PooledEmbedding``. The model runs on the
/// CPU and the Apple Neural Engine, one text at a time, because its inputs
/// have a fixed size of one row.
struct CoreMLEmbedding: PooledEmbedding {
    /// The model of the key that loaded this model. The embed telemetry of
    /// each call records it.
    private let ref: ModelRef

    /// The loaded Core ML model. `MLModel` is not `Sendable`, but only the
    /// embed calls use it, and ``lock`` runs them one at a time.
    private nonisolated(unsafe) let model: MLModel

    /// The names and the size of the inputs and the output of the model.
    private let contract: CoreMLEmbeddingContract

    /// The tokenizer of the model.
    private let tokenizer: any MLXLMCommon.Tokenizer

    /// The lock that runs the embed calls of this model one at a time.
    private let lock = CoreMLEmbedLock()

    /// Loads the model package of a snapshot, and its tokenizer.
    ///
    /// The first load of a commit compiles the package and keeps the compiled
    /// model in the cache folder. Each later load of the commit reads the
    /// compiled model.
    ///
    /// - Parameters:
    ///   - ref: The model of the key of the load.
    ///   - snapshot: The snapshot folder of the model.
    ///   - cacheDirectory: The folder of the Hugging Face cache, which holds
    ///     the compiled models.
    ///   - tokenizerLoader: The loader of the tokenizer of the model.
    /// - Returns: The loaded model.
    /// - Throws: ``CoreMLModelLoaderError`` when the snapshot holds no usable
    ///   package, or the error of the compile, the load or the tokenizer.
    static func load(
        ref: ModelRef, snapshot: URL, cacheDirectory: URL, tokenizerLoader: any TokenizerLoader
    ) async throws -> CoreMLEmbedding {
        let package = try CoreMLPackage.locate(in: snapshot, repository: ref.repo)
        let commit =
            ref.localDirectory == nil ? snapshot.lastPathComponent : CoreMLPackage.localRevision(of: package)
        let compiled = CoreMLPackage.compiledModel(in: cacheDirectory, repository: ref.repo, commit: commit)
        let model = try await loadModel(package: package, compiled: compiled)
        let contract = try CoreMLEmbeddingContract(description: model.modelDescription)
        let tokenizer = try await CoreMLPackage.withTokenizerFolder(of: snapshot) { folder in
            try await tokenizerLoader.load(from: folder)
        }
        return CoreMLEmbedding(ref: ref, model: model, contract: contract, tokenizer: tokenizer)
    }

    /// Makes an embedding model over a loaded model and tokenizer.
    private init(ref: ModelRef, model: MLModel, contract: CoreMLEmbeddingContract, tokenizer: any MLXLMCommon.Tokenizer) {
        self.ref = ref
        self.model = model
        self.contract = contract
        self.tokenizer = tokenizer
    }

    /// Gives one vector for each text. The call waits for each earlier call of
    /// this model, then tokenizes `texts`, and runs the model on each text. The
    /// model gives a pooled and normalized vector, thus this adds no pooling.
    /// A text of more tokens than the model reads keeps its first tokens and
    /// its end token.
    ///
    /// The call runs in the embed span of ``EmbedTelemetry``. The token budget
    /// of its sub-batches is the token count of one model input, thus a row
    /// that the model cuts shows as an over-budget row.
    ///
    /// - Parameter texts: The texts. The caller adds any prefix that the model
    ///   expects, such as a query prefix.
    /// - Returns: One vector for each text, in the order of `texts`.
    /// - Throws: The error of the prediction, or of the embed telemetry.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await lock.run {
            try await EmbedTelemetry.traceEmbed(
                of: ref, texts: texts, tokenBudget: contract.sequenceLength,
                tokenize: { CoreMLTokenRow.encode($0, with: tokenizer) },
                vectors: { try $0.map(vector(of:)) })
        }
    }

    /// Runs the model on one row of tokens.
    ///
    /// - Parameter tokens: The tokens of one text.
    /// - Returns: The vector of the text.
    /// - Throws: The error of the prediction, or
    ///   ``CoreMLModelLoaderError/unsupportedModel(reason:)`` when the model
    ///   gives no array.
    private func vector(of tokens: [Int]) throws -> [Float] {
        let row = CoreMLTokenRow(tokens: tokens, tokenizer: tokenizer, length: contract.sequenceLength)
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            CoreMLEmbeddingContract.inputIDsName: Self.array(of: row.ids),
            CoreMLEmbeddingContract.attentionMaskName: Self.array(of: row.mask),
        ])
        let output = try model.prediction(from: inputs)
        guard let vector = output.featureValue(for: contract.outputName)?.multiArrayValue else {
            throw CoreMLModelLoaderError.unsupportedModel(reason: "the output \(contract.outputName) is not an array")
        }
        return (0..<vector.count).map { vector[$0].floatValue }
    }

    /// Makes the `int32` input array `[1, count]` of one row.
    ///
    /// - Parameter values: The items of the row.
    /// - Returns: The array.
    /// - Throws: The error of the array allocation.
    private static func array(of values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: value)
        }
        return array
    }

    /// Loads the compiled model when the cache holds it, else compiles the
    /// package and keeps the result in the cache. A compiled model that does
    /// not load, for example after an update of the system, is removed and
    /// made again.
    ///
    /// - Parameters:
    ///   - package: The folder of the model package.
    ///   - compiled: The place of the compiled model in the cache.
    /// - Returns: The model, set to run on the CPU and the Neural Engine.
    /// - Throws: The error of the compile or of the load.
    private static func loadModel(package: URL, compiled: URL) async throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let files = FileManager.default
        if files.fileExists(atPath: compiled.path) {
            if let model = try? await MLModel.load(contentsOf: compiled, configuration: configuration) {
                return model
            }
            try files.removeItem(at: compiled)
        }
        try await compile(package: package, into: compiled)
        return try await MLModel.load(contentsOf: compiled, configuration: configuration)
    }

    /// Compiles a model package, and moves the result to `compiled`. When a
    /// second process made the compiled model first, this keeps that model.
    ///
    /// - Parameters:
    ///   - package: The folder of the model package.
    ///   - compiled: The place of the compiled model in the cache.
    /// - Throws: The error of the compile or of the move.
    private static func compile(package: URL, into compiled: URL) async throws {
        let files = FileManager.default
        let workFolder = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? files.removeItem(at: workFolder) }
        let copy = workFolder.appending(path: package.lastPathComponent, directoryHint: .isDirectory)
        try CoreMLPackage.copy(package, to: copy)
        let temporary = try await MLModel.compileModel(at: copy)
        defer { try? files.removeItem(at: temporary) }
        try files.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try files.moveItem(at: temporary, to: compiled)
        } catch where files.fileExists(atPath: compiled.path) {
            return
        }
    }
}
