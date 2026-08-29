import FoundationModels
import NotesToolCore
import Operations

/// Drives the scripted live-model validation `notes --chat` runs, per
/// plan.md's task 7: op-call accuracy over a scripted prompt set, rendered
/// tool-definition size via `tokenCount(for:)` (including the
/// `includesSchemaInInstructions` on/off delta), and the retry-cap behavior
/// on a deliberately invalid request.
///
/// Manual-run only, never part of `swift test`: it needs an Apple
/// Intelligence-enabled device, which CI does not have (plan.md's
/// "Toolchain" risk) — `run()` degrades to a skip message off-device instead
/// of failing.
internal enum ChatValidationHarness {
    /// One scripted prompt and the op the notes tool should be dispatched to
    /// in response.
    private struct ScriptedPrompt: Sendable {
        /// The natural-language prompt sent to the model.
        internal let prompt: String

        /// The `"verb noun"` op string the model is expected to dispatch.
        internal let expectedOpString: String
    }

    /// The scripted prompt set: one prompt per notes operation.
    private static let scriptedPrompts: [ScriptedPrompt] = [
        ScriptedPrompt(prompt: "Add a note titled 'Groceries' with body 'Milk, eggs, bread'.", expectedOpString: "add note"),
        ScriptedPrompt(prompt: "List all my notes.", expectedOpString: "list note"),
        ScriptedPrompt(prompt: "Get the note with id note-1.", expectedOpString: "get note"),
        ScriptedPrompt(prompt: "Tag note note-1 with 'urgent' and 'errands'.", expectedOpString: "tag note"),
        ScriptedPrompt(prompt: "Delete the note with id note-1.", expectedOpString: "delete note"),
    ]

    /// A request no notes operation supports, for observing the retry-cap
    /// probe's corrective/terminal messages.
    private static let deliberatelyInvalidPrompt = "Frobnicate the note with id note-1 using the notes tool."

    /// The instructions the harness's `LanguageModelSession`s run under.
    private static let sessionInstructions = "You manage the user's notes using the notes tool. Always use the tool for note operations."

    /// Runs the live-model validation if `SystemLanguageModel` is available
    /// on this device, otherwise prints a skip message explaining why.
    internal static func run() async {
        switch SystemLanguageModel.default.availability {
        case .available:
            await runValidation()
        case .unavailable(let reason):
            let reasonText: String
            switch reason {
            case .deviceNotEligible: reasonText = "device not eligible"
            case .appleIntelligenceNotEnabled: reasonText = "Apple Intelligence not enabled"
            case .modelNotReady: reasonText = "model not ready"
            @unknown default: reasonText = "unknown reason"
            }
            print("Foundation Models unavailable on this device (\(reasonText)); skipping live validation.")
        @unknown default:
            print("Foundation Models availability is unknown on this device; skipping live validation.")
        }
    }

    /// Runs every stage of the validation report in turn.
    private static func runValidation() async {
        do {
            try await reportTokenCounts()

            let tool = try NotesTool.make()
            let session = LanguageModelSession(tools: [tool], instructions: sessionInstructions)
            let accuracy = await measureOpCallAccuracy(session: session, toolName: tool.name)
            print("Op-call accuracy: \(accuracy.matched)/\(accuracy.total) scripted prompts dispatched the expected op.")

            await probeRetryCapBehavior(session: session)
        } catch {
            print("Live validation failed: \(error)")
        }
    }

    /// Prints the fused tool's rendered schema size, with and without
    /// `includesSchemaInInstructions`, and the delta between them.
    ///
    /// - Throws: Rethrows from `NotesTool.make(includesSchemaInInstructions:)`
    ///   or `SystemLanguageModel.tokenCount(for:)`.
    private static func reportTokenCounts() async throws {
        guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else {
            print("Token-count reporting requires macOS/iOS/visionOS 26.4 or newer; skipping.")
            return
        }
        let model = SystemLanguageModel.default
        let withSchema = try await model.tokenCount(for: [try NotesTool.make(includesSchemaInInstructions: true)])
        let withoutSchema = try await model.tokenCount(for: [try NotesTool.make(includesSchemaInInstructions: false)])
        print("Tool schema token count (includesSchemaInInstructions=true): \(withSchema)")
        print("Tool schema token count (includesSchemaInInstructions=false): \(withoutSchema)")
        print("includesSchemaInInstructions delta: \(withSchema - withoutSchema)")
    }

    /// Sends every `scriptedPrompts` entry to `session` and tallies how many
    /// dispatched their expected op.
    ///
    /// - Parameters:
    ///   - session: The session to send scripted prompts to.
    ///   - toolName: The fused tool's name, to find its calls in the
    ///     session's transcript after each response.
    /// - Returns: The number of prompts that matched, out of the total.
    private static func measureOpCallAccuracy(
        session: LanguageModelSession,
        toolName: String
    ) async -> (matched: Int, total: Int) {
        var matched = 0
        for scripted in scriptedPrompts where await evaluateScriptedPrompt(scripted, session: session, toolName: toolName) {
            matched += 1
        }
        return (matched, scriptedPrompts.count)
    }

    /// Sends one scripted prompt to `session`, prints whether the resulting
    /// tool call matched its expected op, and reports the outcome.
    ///
    /// - Parameters:
    ///   - scripted: The prompt and its expected op string.
    ///   - session: The session to send the prompt to.
    ///   - toolName: The fused tool's name, to find its call in the
    ///     transcript.
    /// - Returns: Whether the dispatched op matched `scripted.expectedOpString`.
    private static func evaluateScriptedPrompt(
        _ scripted: ScriptedPrompt,
        session: LanguageModelSession,
        toolName: String
    ) async -> Bool {
        do {
            _ = try await session.respond(to: scripted.prompt)
            let actual = lastToolCallOpString(in: session.transcript, toolName: toolName)
            let matched = actual == scripted.expectedOpString
            let status = matched ? "OK" : "MISS"
            print("[\(status)] \"\(scripted.prompt)\" -> expected '\(scripted.expectedOpString)', got '\(actual ?? "none")'")
            return matched
        } catch {
            print("[ERROR] \"\(scripted.prompt)\" -> \(error)")
            return false
        }
    }

    /// Sends `deliberatelyInvalidPrompt` to `session` three times in a row,
    /// printing each response so a human can observe the retry cap's
    /// corrective messages give way to its terminal one (plan.md's "Retry
    /// cap").
    ///
    /// - Parameter session: The session to send the probe requests to.
    private static func probeRetryCapBehavior(session: LanguageModelSession) async {
        print("Retry-cap probe: sending a deliberately invalid request 3 times in a row.")
        for attempt in 1...3 {
            do {
                let response = try await session.respond(to: deliberatelyInvalidPrompt)
                print("[attempt \(attempt)] model responded: \(response.content)")
            } catch {
                print("[attempt \(attempt)] session threw: \(error)")
            }
        }
    }

    /// The `op` argument of the most recent call to the tool named
    /// `toolName` in `transcript`, or `nil` if it contains none.
    ///
    /// - Parameters:
    ///   - transcript: The session transcript to search.
    ///   - toolName: The tool name to match `Transcript.ToolCall.toolName`
    ///     against.
    private static func lastToolCallOpString(in transcript: Transcript, toolName: String) -> String? {
        var lastMatch: String?
        for entry in transcript {
            guard case .toolCalls(let calls) = entry else { continue }
            for call in calls where call.toolName == toolName {
                lastMatch = try? call.arguments.value(String.self, forProperty: OperationKeys.opFieldName)
            }
        }
        return lastMatch
    }
}
