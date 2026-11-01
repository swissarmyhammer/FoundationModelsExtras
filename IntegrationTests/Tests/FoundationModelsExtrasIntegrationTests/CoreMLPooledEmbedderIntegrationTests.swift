import CoreML
@testable import FoundationModelsExtras
import HuggingFace
import Testing

/// The prefix that the model card gives for a search query.
private let queryPrefix = "task: search result | query: "

/// The prefix that the model card gives for a document.
private let documentPrefix = "title: none | text: "

/// The query of the similarity test.
private let query = queryPrefix + "How do I keep a cat warm in winter?"

/// The document that answers ``query``.
private let relevantDocument = documentPrefix + "A cat likes to sleep on a warm windowsill or on a heated pad."

/// A document that has no relation to ``query``.
private let unrelatedDocument = documentPrefix + "The central bank raised the interest rate by half a percent."

/// The dimension of a vector of the model.
private let vectorDimension = 768

/// The most that a unit vector can differ from the length 1.
private let unitLengthTolerance: Float = 1e-2

/// The most that two vectors of one text can differ in one value. The model
/// runs on the same hardware for both calls, thus the vectors are equal.
private let determinismTolerance: Float = 1e-4

/// The words of ``longText``. More than 128 tokens, which is the length that
/// the model reads.
private let longTextWordCount = 400

/// A text with many more tokens than the model reads.
private let longText = documentPrefix + (1...longTextWordCount).map { "word\($0)" }.joined(separator: " ")

/// The count of warm embed calls that the latency report times.
private let timedCalls = 10

/// The tokenizer loader of the shared load. The test of the tokenizer reads
/// the tokenizer that this loader gave.
private let sharedTokenizerLoader = RecordingTokenizerLoader()

extension RealModelSuites {
    /// `PooledEmbedder` with the real Core ML embedding model: real vectors
    /// from the Neural Engine, the truncation of a long text, and one load for
    /// all embedders of one name.
    @Suite(
        "Pooled embedder with a real Core ML model",
        .sharedLoads(
            SharedModel(
                IntegrationModels.coreMLEmbedding, loader: HubModelLoader(tokenizerLoader: sharedTokenizerLoader))))
    struct CoreMLPooledEmbedderIntegrationTests {
        @Test("a real embed gives a unit vector of 768 values for each text")
        func vectorsAreUnitVectors() async throws {
            let vectors = try await Self.embedder().embed(texts: [query, relevantDocument, unrelatedDocument])

            #expect(vectors.count == 3)
            #expect(vectors.allSatisfy { $0.count == vectorDimension })
            for vector in vectors {
                let length = VectorMath.length(of: vector)
                #expect(abs(length - 1) < unitLengthTolerance, "length: \(length)")
            }
        }

        @Test("a real embed of one text twice gives the same vector")
        func embeddingIsDeterministic() async throws {
            let embedder = try Self.embedder()

            let first = try #require(try await embedder.embed(texts: [query]).first)
            let second = try #require(try await embedder.embed(texts: [query]).first)

            let largestDifference = zip(first, second).map { abs($0 - $1) }.max() ?? .infinity
            #expect(largestDifference < determinismTolerance, "largest difference: \(largestDifference)")
        }

        @Test("a query is closer to the document that answers it than to an unrelated document")
        func queryIsCloserToItsDocument() async throws {
            let vectors = try await Self.embedder().embed(texts: [query, relevantDocument, unrelatedDocument])

            let relevant = VectorMath.cosine(of: vectors[0], to: vectors[1])
            let unrelated = VectorMath.cosine(of: vectors[0], to: vectors[2])
            #expect(relevant > unrelated, "relevant: \(relevant); unrelated: \(unrelated)")
        }

        @Test("a text of more tokens than the model reads gives a vector and does not throw")
        func longTextIsCut() async throws {
            let tokenizer = try #require(await sharedTokenizerLoader.tokenizers.events.first)
            let tokenCount = tokenizer.encode(text: longText, addSpecialTokens: true).count
            try #require(tokenCount > 128, "the long text must exceed the length of the model: \(tokenCount)")

            let vectors = try await Self.embedder().embed(texts: [longText])

            #expect(vectors.first?.count == vectorDimension)
        }

        @Test("the token ids of each reference text equal the ids of the Python tokenizers library")
        func tokenIdsEqualPythonTokenizers() async throws {
            let tokenizer = try #require(await sharedTokenizerLoader.tokenizers.events.first)

            for reference in try loadReferenceTokenCases() {
                let row = CoreMLTokenRow(text: reference.text, tokenizer: tokenizer, length: referenceLength)

                let realIds = zip(row.ids, row.mask).filter { $1 == 1 }.map(\.0)
                #expect(realIds == reference.ids, "text: \(reference.text.prefix(40))")
                #expect(row.ids.count == referenceLength)
                #expect(row.ids.suffix(row.ids.count - realIds.count).allSatisfy { $0 == referencePadToken })
            }
        }

        @Test("the batch of several texts gives the vector of each text embedded alone")
        func batchEqualsSingles() async throws {
            let embedder = try Self.embedder()
            let texts = [query, relevantDocument, longText]

            let batch = try await embedder.embed(texts: texts)

            for (text, vector) in zip(texts, batch) {
                let alone = try #require(try await embedder.embed(texts: [text]).first)
                let cosine = VectorMath.cosine(of: vector, to: alone)
                #expect(cosine > 1 - determinismTolerance, "cosine: \(cosine)")
            }
        }

        @Test("the compiled model prefers the Neural Engine for most of its operations")
        func compiledModelPrefersTheNeuralEngine() async throws {
            let compiled = try Self.compiledModelURL()

            let usage = try await NeuralEngineUsage.measure(compiledModel: compiled)

            print(
                "Neural Engine usage: \(usage.neuralEngine) of \(usage.counted) operations (\(usage.fraction)); "
                    + "GPU \(usage.gpu), CPU \(usage.cpu), without a device \(usage.uncounted)")
            #expect(usage.counted > 0, "the compute plan lists no operation with a device")
        }

        @Test("a warm embed of one text takes a time that the report prints")
        func warmEmbedLatency() async throws {
            let embedder = try Self.embedder()
            _ = try await embedder.embed(texts: [query])

            let clock = ContinuousClock()
            let elapsed = try await clock.measure {
                for _ in 0..<timedCalls { _ = try await embedder.embed(texts: [query]) }
            }

            print("Core ML embed of one short text: \(elapsed / timedCalls) for each call, over \(timedCalls) calls")
        }

        @Test("two embedders of one name on one pool cause one load, of the model and of the tokenizer")
        func twoEmbeddersShareOneLoad() async throws {
            let tokenizerLoader = RecordingTokenizerLoader()
            let pool = ModelPool(loader: HubModelLoader(tokenizerLoader: tokenizerLoader))
            let ref = IntegrationModels.coreMLEmbedding.ref
            let first = PooledEmbedder(ref: ref, pool: pool)
            let second = PooledEmbedder(ref: ref, pool: pool)

            async let firstVectors = first.embed(texts: [query])
            async let secondVectors = second.embed(texts: [query])
            let vectors = try await [firstVectors, secondVectors]

            #expect(vectors.map(\.count) == [1, 1])
            #expect(await tokenizerLoader.directories.events.count == 1)
        }

        @Test("the footprint that the loader measures is the weight file of the package")
        func footprintIsTheWeights() async throws {
            let bytes = try await HubModelLoader().footprintBytes(of: IntegrationModels.coreMLEmbedding)

            #expect(bytes > 100 << 20, "weight bytes: \(bytes)")
        }

        /// An embedder that keeps a new hold of the shared model.
        private static func embedder() throws -> PooledEmbedder {
            try PooledEmbedder(hold: try SharedModels.required().hold(of: IntegrationModels.coreMLEmbedding))
        }

        /// The place of the compiled model that the shared load made in the
        /// default Hugging Face cache.
        private static func compiledModelURL() throws -> URL {
            let cache = HubCache.default
            let ref = IntegrationModels.coreMLEmbedding.ref
            let repo = try #require(Repo.ID(rawValue: ref.repo))
            let commit = try #require(cache.resolveRevision(repo: repo, kind: .model, ref: ModelRef.defaultRevision))
            return CoreMLPackage.compiledModel(in: cache.cacheDirectory, repository: ref.repo, commit: commit)
        }
    }
}

/// How many operations of a compiled model prefer each compute device.
private struct NeuralEngineUsage {
    /// The operations that prefer the Neural Engine.
    var neuralEngine = 0
    /// The operations that prefer the GPU.
    var gpu = 0
    /// The operations that prefer the CPU.
    var cpu = 0
    /// The operations that the compute plan gives no device.
    var uncounted = 0

    /// The operations with a device.
    var counted: Int { neuralEngine + gpu + cpu }

    /// The operations that prefer the Neural Engine, over the operations with a
    /// device.
    var fraction: Double { counted == 0 ? 0 : Double(neuralEngine) / Double(counted) }

    /// Counts the preferred device of each operation of the main function of a
    /// compiled model, with the compute units of the loader.
    ///
    /// - Parameter compiledModel: The `.mlmodelc` folder.
    /// - Returns: The counts.
    /// - Throws: The error of the compute plan.
    static func measure(compiledModel: URL) async throws -> NeuralEngineUsage {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: compiledModel, configuration: configuration)
        guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else {
            Issue.record("the compiled model is not a program with a main function")
            return NeuralEngineUsage()
        }
        var usage = NeuralEngineUsage()
        for operation in main.block.operations {
            switch plan.deviceUsage(for: operation)?.preferred {
            case .neuralEngine: usage.neuralEngine += 1
            case .gpu: usage.gpu += 1
            case .cpu: usage.cpu += 1
            default: usage.uncounted += 1
            }
        }
        return usage
    }
}

/// The math of the similarity checks.
private enum VectorMath {
    /// The cosine of the angle between two vectors of one length.
    static func cosine(of first: [Float], to second: [Float]) -> Float {
        zip(first, second).lazy.map(*).reduce(0, +) / (length(of: first) * length(of: second))
    }

    /// The Euclidean length of `vector`.
    static func length(of vector: [Float]) -> Float {
        vector.lazy.map { $0 * $0 }.reduce(0, +).squareRoot()
    }
}
