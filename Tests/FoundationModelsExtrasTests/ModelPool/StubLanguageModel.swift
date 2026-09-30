import FoundationModels

/// The script that each copy of one ``StubLanguageModel`` plays. The model
/// and the test share it, thus the test reads the log of the calls here.
///
/// A class, because the identity of the script is the cache key of the
/// executor. Each stored property is `Sendable`, thus the `Sendable`
/// conformance is compiler-checked.
final class StubLanguageModelScript: Sendable {
    /// The log of the generation calls.
    let log: Recorder<String>

    /// The first generation call ends only after this stream finishes.
    fileprivate let firstCallMayEnd: AsyncStream<Void>

    /// Makes the answer of a generation call from the text of each prompt of
    /// the transcript, in order.
    fileprivate let answer: @Sendable (_ prompts: [String]) -> String

    /// The number of generation calls that started.
    fileprivate let startedCalls = Counter()

    /// Makes a script.
    ///
    /// - Parameters:
    ///   - log: The log of the generation calls.
    ///   - firstCallMayEnd: The first call ends only after this stream
    ///     finishes. The default stream is finished, so the first call ends
    ///     at once.
    ///   - answer: Makes the answer from the text of each prompt of the
    ///     transcript, in order. The default joins the prompts with a space,
    ///     thus an answer shows each prompt that the session remembers.
    init(
        log: Recorder<String> = Recorder(),
        firstCallMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        answer: @escaping @Sendable (_ prompts: [String]) -> String = { $0.joined(separator: " ") }
    ) {
        self.log = log
        self.firstCallMayEnd = firstCallMayEnd
        self.answer = answer
    }
}

/// A FoundationModels `LanguageModel` that loads nothing and plays a
/// ``StubLanguageModelScript``.
///
/// A generation call writes `"begin <last prompt>"` and then
/// `"end <last prompt>"` to the log of the script. The first call waits
/// between the two writes until the `firstCallMayEnd` stream of the script
/// finishes. The call then answers with the answer of the script.
struct StubLanguageModel: LanguageModel {
    /// The executor that plays the script.
    typealias Executor = StubLanguageModelExecutor

    /// The script that the model plays.
    let script: StubLanguageModelScript

    /// Guided generation, so a session can ask for a `Generable` type.
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration])
    }

    /// The cache key of the executor: the identity of the script.
    var executorConfiguration: StubLanguageModelExecutor.Configuration {
        StubLanguageModelExecutor.Configuration(script: ObjectIdentifier(script))
    }
}

/// The executor of ``StubLanguageModel``.
struct StubLanguageModelExecutor: LanguageModelExecutor {
    /// The cache key that the SDK makes and reuses the executor by.
    struct Configuration: Sendable, Hashable {
        /// The identity of the script that the model plays.
        let script: ObjectIdentifier
    }

    /// The model that this executor runs for.
    typealias Model = StubLanguageModel

    /// The number of the first generation call, which waits for the gate of
    /// the script.
    private static let firstCall = 1

    /// The token count of the one emitted fragment. The stub meters nothing.
    private static let emittedTokenCount = 1

    /// Makes an executor. The configuration holds nothing that the executor
    /// reads: the script arrives with the model on each call.
    ///
    /// - Parameter configuration: The cache key.
    /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
    ///   requirement.
    init(configuration: Configuration) throws {}

    /// Writes the call to the log, waits for the gate on the first call, and
    /// emits the answer of the script.
    ///
    /// - Parameters:
    ///   - request: The generation request with the full transcript.
    ///   - model: The model with the script.
    ///   - channel: The channel that the answer goes into.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: StubLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let script = model.script
        let prompts = Self.promptTexts(in: request.transcript)
        let name = prompts.last ?? ""
        script.log.append("begin \(name)")
        if script.startedCalls.next() == Self.firstCall {
            for await _ in script.firstCallMayEnd {}
        }
        script.log.append("end \(name)")
        await channel.send(.response(action: .appendText(script.answer(prompts), tokenCount: Self.emittedTokenCount)))
    }

    /// The text of each prompt of `transcript`, in order.
    ///
    /// - Parameter transcript: The transcript of a generation call.
    /// - Returns: The text of each prompt entry.
    private static func promptTexts(in transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { segment in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
    }
}
