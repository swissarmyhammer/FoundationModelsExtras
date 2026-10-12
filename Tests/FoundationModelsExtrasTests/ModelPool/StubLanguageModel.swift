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

    /// The output token count that each answer gives in an `updateUsage`
    /// event after its text, or `nil` when the answer gives no usage.
    fileprivate let outputTokenCount: Int?

    /// The name of the tool that the model calls one time before it answers,
    /// or `nil` when the model calls no tool.
    fileprivate let toolName: String?

    /// The number of generation calls that started.
    fileprivate let startedCalls = Counter()

    /// Makes a script.
    ///
    /// - Parameters:
    ///   - log: The log of the generation calls.
    ///   - firstCallMayEnd: The first call ends only after this stream
    ///     finishes. The default stream is finished, so the first call ends
    ///     at once.
    ///   - outputTokenCount: The output token count that each answer gives
    ///     in an `updateUsage` event, or `nil` for no usage event. The
    ///     default is `nil`.
    ///   - toolName: The name of the tool that the model calls with the
    ///     arguments `{}` before it answers, or `nil` for no tool call. The
    ///     default is `nil`.
    ///   - answer: Makes the answer from the text of each prompt of the
    ///     transcript, in order. The default joins the prompts with a space,
    ///     thus an answer shows each prompt that the session remembers.
    init(
        log: Recorder<String> = Recorder(),
        firstCallMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        outputTokenCount: Int? = nil,
        toolName: String? = nil,
        answer: @escaping @Sendable (_ prompts: [String]) -> String = { $0.joined(separator: " ") }
    ) {
        self.log = log
        self.firstCallMayEnd = firstCallMayEnd
        self.outputTokenCount = outputTokenCount
        self.toolName = toolName
        self.answer = answer
    }
}

/// A FoundationModels `LanguageModel` that loads nothing and plays a
/// ``StubLanguageModelScript``.
///
/// A generation call writes `"begin <last prompt>"` and then
/// `"end <last prompt>"` to the log of the script. The first call waits
/// between the two writes until the `firstCallMayEnd` stream of the script
/// finishes. When the script names a tool and the transcript holds no tool
/// output yet, the call then asks for that tool and ends. Else the call
/// answers with the answer of the script, and then gives the usage of the
/// script when it has one.
struct StubLanguageModel: LanguageModel {
    /// The executor that plays the script.
    typealias Executor = StubLanguageModelExecutor

    /// The script that the model plays.
    let script: StubLanguageModelScript

    /// Guided generation and tool calls, so a session can ask for a
    /// `Generable` type and call a tool.
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration, .toolCalling])
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

    /// The id of the one tool call that the stub asks for.
    private static let toolCallID = "stub-tool-call"

    /// The arguments of the one tool call that the stub asks for: a tool
    /// with no argument.
    private static let toolCallArguments = "{}"

    /// The input, cached and reasoning token counts of the usage of the stub.
    /// The stub meters only its output tokens, thus each other count is zero.
    private static let noTokens = 0

    /// Makes an executor. The configuration holds nothing that the executor
    /// reads: the script arrives with the model on each call.
    ///
    /// - Parameter configuration: The cache key.
    /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
    ///   requirement.
    init(configuration: Configuration) throws {}

    /// Writes the call to the log, waits for the gate on the first call, and
    /// asks for the tool of the script or emits the answer of the script.
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
        if let toolName = script.toolName, !Self.holdsToolOutput(request.transcript) {
            await Self.askForTool(named: toolName, into: channel)
            return
        }
        await channel.send(.response(action: .appendText(script.answer(prompts), tokenCount: Self.emittedTokenCount)))
        if let outputTokenCount = script.outputTokenCount {
            await Self.sendUsage(outputTokenCount: outputTokenCount, into: channel)
        }
    }

    /// Asks for one call of the tool `toolName` with no argument.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool.
    ///   - channel: The channel that the tool call goes into.
    private static func askForTool(named toolName: String, into channel: LanguageModelExecutorGenerationChannel) async {
        await channel.send(
            .toolCalls(
                action: .toolCall(
                    id: toolCallID, name: toolName,
                    action: .appendArguments(toolCallArguments, tokenCount: emittedTokenCount))))
    }

    /// Gives the usage of one answer: no input token, and `outputTokenCount`
    /// output tokens.
    ///
    /// - Parameters:
    ///   - outputTokenCount: The output token count of the answer.
    ///   - channel: The channel that the usage goes into.
    private static func sendUsage(outputTokenCount: Int, into channel: LanguageModelExecutorGenerationChannel) async {
        await channel.send(
            .response(
                action: .updateUsage(
                    input: .init(totalTokenCount: noTokens, cachedTokenCount: noTokens),
                    output: .init(totalTokenCount: outputTokenCount, reasoningTokenCount: noTokens))))
    }

    /// Whether `transcript` holds the output of a tool call.
    ///
    /// - Parameter transcript: The transcript of a generation call.
    /// - Returns: `true` when an entry is a tool output.
    private static func holdsToolOutput(_ transcript: Transcript) -> Bool {
        transcript.contains { entry in
            guard case .toolOutput = entry else { return false }
            return true
        }
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
