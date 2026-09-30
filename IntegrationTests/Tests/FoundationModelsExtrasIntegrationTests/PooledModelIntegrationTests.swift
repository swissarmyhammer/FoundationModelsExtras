import FoundationModels
import FoundationModelsExtras
import Testing

/// The instructions of each session of this suite. Short answers keep each
/// test fast.
private let shortAnswers = "You are a helpful assistant. Answer in as few words as you can."

/// A question with one well-known answer, and that answer.
private enum CapitalQuestion {
    /// The question.
    static let prompt = "What is the capital of France?"
    /// The word that the answer contains.
    static let answer = "paris"
}

/// A question whose answer is a number, and that number.
private enum LegCountQuestion {
    /// The question.
    static let prompt = "How many legs does a spider have?"
    /// The number of legs of a spider.
    static let legCount = 8
}

/// A fact that the parent session hears, and the question that the fork asks.
private enum RememberedFact {
    /// The color that the parent session hears.
    static let color = "teal"
    /// The prompt that tells the fact to the parent session.
    static let statement = "My favorite color is \(color). Remember it, and answer only OK."
    /// The question that the fork asks.
    static let question = "What is my favorite color? Answer with the color only."
}

/// The typed answer of the typed respond test.
@Generable
private struct LegCount {
    /// The number of legs.
    @Guide(description: "The number of legs, as a number")
    let legs: Int
}

extension RealModelSuites {
    /// `PooledModel` and `PooledSession` with the real
    /// `mlx-community/Qwen3-4B-4bit`, which `ModelPool()` loads by name with
    /// `MLXModelLoader`.
    @Suite("Pooled model with a real LLM", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct PooledModelIntegrationTests {
        /// The LLM of this suite.
        private static let key = IntegrationModels.toolCallingLLM

        @Test("a session of the real model answers a question")
        func aSessionAnswers() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let answer = try await Self.respond(to: CapitalQuestion.prompt, in: pool)
            try await IntegrationModels.waitForEviction(of: Self.key, in: pool)

            #expect(answer.lowercased().contains(CapitalQuestion.answer), "answer: \(answer)")
        }

        @Test("respond(to:generating:) decodes the answer of the real model as a Generable type")
        func aTypedRespondDecodesTheAnswer() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let answer = try await Self.respondWithLegCount(in: pool)
            try await IntegrationModels.waitForEviction(of: Self.key, in: pool)

            #expect(answer.legs == LegCountQuestion.legCount)
        }

        @Test("a fork of a real session remembers a fact that its parent heard")
        func aForkRemembersAFactOfItsParent() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let answer = try await Self.askTheForkForTheFact(in: pool)
            try await IntegrationModels.waitForEviction(of: Self.key, in: pool)

            #expect(answer.lowercased().contains(RememberedFact.color), "answer: \(answer)")
        }

        /// Asks `prompt` in a new session of the model of this suite. The
        /// session goes when the call returns.
        ///
        /// - Parameters:
        ///   - prompt: The question.
        ///   - pool: The pool of the test.
        /// - Returns: The text of the answer.
        /// - Throws: The error of the load or of the generation.
        private static func respond(to prompt: String, in pool: ModelPool) async throws -> String {
            let session = try await PooledModel(ref: key.ref, pool: pool).session(instructions: shortAnswers)
            return try await session.respond(to: prompt)
        }

        /// Asks the leg count question as a ``LegCount`` in a new session of
        /// the model of this suite. The session goes when the call returns.
        ///
        /// - Parameter pool: The pool of the test.
        /// - Returns: The typed answer.
        /// - Throws: The error of the load, of the generation or of the decode.
        private static func respondWithLegCount(in pool: ModelPool) async throws -> LegCount {
            let session = try await PooledModel(ref: key.ref, pool: pool).session(instructions: shortAnswers)
            return try await session.respond(to: LegCountQuestion.prompt, generating: LegCount.self)
        }

        /// Tells the fact to a new session, forks the session, and asks the
        /// fork for the fact. The sessions go when the call returns.
        ///
        /// - Parameter pool: The pool of the test.
        /// - Returns: The text of the answer of the fork.
        /// - Throws: The error of the load or of a generation.
        private static func askTheForkForTheFact(in pool: ModelPool) async throws -> String {
            let parent = try await PooledModel(ref: key.ref, pool: pool).session(instructions: shortAnswers)
            _ = try await parent.respond(to: RememberedFact.statement)
            let fork = try await parent.fork()
            return try await fork.respond(to: RememberedFact.question)
        }
    }
}
