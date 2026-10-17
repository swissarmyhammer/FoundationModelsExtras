import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

/// The timeout of the mount of ``StuckRecordTool``, in seconds. The tool works
/// until the test opens its gate, after the model call returned.
private let stuckToolTimeoutSeconds: TimeInterval = 2

/// The settle period of a host whose background calls must answer with the
/// pending envelope at once, also when the run is fast.
private let pendingAtOnceGrace: TimeInterval = 0

/// The instructions of the sessions of the tool-hosting suite.
private enum SessionInstructions {
    /// The instructions of a session with one tool that the model must call
    /// one time, and whose output the model must repeat.
    ///
    /// - Parameter tool: The name of the tool.
    /// - Returns: The instructions.
    static func callingOnce(_ tool: String) -> String {
        "You are a helpful assistant. To answer the user, call the \(tool) tool exactly one time. "
            + "Then reply with what the tool returned, word for word."
    }

    /// The instructions of a session in which the model must make one
    /// background call and one synchronous call. The background result comes
    /// later, in a message that the host injects.
    ///
    /// - Parameters:
    ///   - backgroundCall: How the model makes the background call.
    ///   - synchronousCall: How the model makes the synchronous call.
    /// - Returns: The instructions.
    static func callingBoth(backgroundCall: String, synchronousCall: String) -> String {
        "You are a helpful assistant. To answer the user, first \(backgroundCall). Then \(synchronousCall). "
            + "The result of a run that continues in the background comes later, in a new message. "
            + "When you have both results, reply with both results, word for word."
    }
}

/// The messages that the host injects into a session of the tool-hosting
/// suite, the same as a real session does.
private enum HostMessage {
    /// The message that gives the model the result of a background run that
    /// settled.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - terminal: The terminal event of the run.
    /// - Returns: The message.
    static func settledRun(completionToken: String, terminal: OperationEvent) -> String {
        "The background run with completion token \"\(completionToken)\" finished. Its result: \(terminal.detail)"
    }
}

extension RealModelSuites {
    /// Tool hosting under a real FoundationModels session: the model calls
    /// mounted tools, and the run plane runs and settles the background runs.
    ///
    /// The unit tests of the mount prove the settle grace of a fast run, the
    /// cancel of a background run, and the per-call mount of a hand-written
    /// tool. These need no real model.
    @Suite(
        "Tool hosting with a real model",
        .sharedLoads(
            SharedModel(IntegrationModels.toolCallingLLM, footprint: IntegrationModels.toolCallingFootprintBytes)))
    struct ToolHostingIntegrationTests {
        @Test("an in-band tool reads its context, posts progress, and the answer of the model holds its result")
        func inBandToolRunsToCompletion() async throws {
            let host = ToolHost()
            let readings = EventLog<ContextReading>()
            let tool = VaultCodeTool(readings: readings)

            let answer = try await ToolSession.answer(
                to: "What is the code of the vault named north?", instructions: SessionInstructions.callingOnce(tool.name),
                tools: [host.mount(tool)], with: try Self.sharedHold())

            #expect(answer.text.contains(VaultCodeTool.code), "answer: \(answer.text)")
            let reading = try #require(await readings.events.first)
            #expect(reading.sessionID == host.sessionID)
            #expect(reading.tool == tool.name)
            let token = try #require(reading.completionToken)
            let progress = await host.events.events.filter { $0.kind == .progress }
            #expect(progress.contains { $0.detail == VaultCodeTool.progressDetail && $0.correlationID == token })
            #expect(await host.runPlane.settledRunTokens().isEmpty)
        }

        @Test("a background tool gives the model a pending envelope, the run settles later, and the observer gets the terminal")
        func backgroundToolSettlesAfterItsEnvelope() async throws {
            let hold = try Self.sharedHold()
            // Grace 0: the call answers with the pending envelope at once.
            let host = ToolHost(inlineSettleGrace: pendingAtOnceGrace)
            let settlements = EventLog<OperationEvent>()
            await host.runPlane.attach(settlementObserver: settlements)
            let gate = Latch()
            // The scan ends also when the test throws.
            defer { gate.open() }
            let tool = ArchiveScanTool(gate: gate)

            let answering = Task {
                try await ToolSession.answer(
                    to: "Start a scan of the archive named west.",
                    instructions: SessionInstructions.callingOnce(tool.name), tools: [host.mount(tool)], with: hold)
            }
            // The scan works until the call gave its pending envelope. A
            // model call that ends with no envelope also opens the gate.
            await Waits.untilFirstEnds(
                { await host.events.waitUntil { $0.contains(where: Self.isPendingEnvelope) } },
                { _ = await answering.result })
            gate.open()
            let answer = try await answering.value

            let envelope = try #require(Self.envelopes(in: answer).first, "tool outputs: \(answer.toolOutputs)")
            #expect(envelope.pending)
            #expect(envelope.next.contains(PendingRunEnvelope.pendingWorkInstruction), "next: \(envelope.next)")
            #expect(!answer.text.contains(ArchiveScanTool.code), "answer: \(answer.text)")
            let terminal = try await Self.terminal(of: envelope.completionToken, in: host)
            #expect(terminal.outcome == .succeeded)
            #expect(terminal.detail == ArchiveScanTool.report)
            // The run plane gives the terminal to the observer after it
            // settles the run, thus this wait follows the settlement.
            #expect(await settlements.waitUntil { !$0.isEmpty } == [terminal])
        }

        @Test("a tool that ignores the cancel past its timeout gives the model the timeout failure, and the model call returns")
        func timeoutReachesTheModelAndTheCallReturns() async throws {
            let host = ToolHost()
            let gate = Latch()
            // The detached work of the tool ends also when the test throws.
            defer { gate.open() }
            let tool = StuckRecordTool(gate: gate)
            let mounted = host.mount(tool, as: ToolMount(mode: .runToCompletion, timeout: stuckToolTimeoutSeconds))

            let answer = try await ToolSession.run(
                instructions: SessionInstructions.callingOnce(tool.name), tools: [mounted], with: try Self.sharedHold()
            ) { session in
                try await ToolSession.answer(to: "Look up the record named alpha.", in: session)
            }
            // The tool works until the gate opens, thus a closed gate shows
            // that the model call did not wait for the tool.
            let returnedWhileTheToolWorked = !gate.isOpen

            let timedOut = ToolMountError.timedOut(tool: tool.name, timeoutSeconds: stuckToolTimeoutSeconds).description
            #expect(answer.toolOutputs.contains(timedOut), "tool outputs: \(answer.toolOutputs)")
            #expect(returnedWhileTheToolWorked)
            #expect(await host.events.events.contains { $0.kind == .completed && $0.outcome == .timedOut })
        }

        @Test("a tool that throws gives the model a failure result, not a thrown error, and the session continues")
        func failureReachesTheModelAsAResult() async throws {
            let host = ToolHost()
            let tool = LockedArchiveTool()
            let archive = "north"

            let (first, followUp) = try await ToolSession.run(
                instructions: SessionInstructions.callingOnce(tool.name), tools: [host.mount(tool)],
                with: try Self.sharedHold()
            ) { session in
                let first = try await ToolSession.answer(to: "Open the archive named \(archive).", in: session)
                let followUp = try await ToolSession.answer(
                    to: "What error code did the tool give? Reply with the error code only.", in: session)
                return (first, followUp.text)
            }

            let failureText = ArchiveLockedError(archive: archive).description
            #expect(first.toolOutputs.contains(failureText), "tool outputs: \(first.toolOutputs)")
            #expect(followUp.contains(ArchiveLockedError.code), "follow-up answer: \(followUp)")
            #expect(await host.events.events.contains { $0.kind == .completed && $0.outcome == .failed })
        }

        @Test("an operation tool gives the model a pending token for its background operation and the real result in band for its synchronous operation, and the model answers from the injected background result")
        func perCallMountOfAnOperationTool() async throws {
            // The scan operation ends at once, so the host states grace 0:
            // the background call answers with the pending envelope at once.
            let host = ToolHost(inlineSettleGrace: pendingAtOnceGrace)
            let tool = try ArchiveOperationTool.make()
            let instructions = SessionInstructions.callingBoth(
                backgroundCall: "call the \(tool.name) tool with op \"\(StartScanOperation.opString)\"",
                synchronousCall: "call the \(tool.name) tool with op \"\(CountFilesOperation.opString)\"")

            let answer = try await Self.answerInjectingSettledRuns(
                to: "Start a scan of the archive and count its files, and tell me both report codes.",
                instructions: instructions, tools: [host.mount(tool)], host: host, with: try Self.sharedHold())

            try await Self.expectPerCallMounts(
                of: answer, in: host, backgroundCode: StartScanOperation.code, synchronousCode: CountFilesOperation.code)
        }

        /// The shared hold of the tool-calling LLM of this suite.
        ///
        /// - Returns: The hold.
        /// - Throws: A failed expectation when the suite has no shared
        ///   tool-calling LLM.
        private static func sharedHold() throws -> ModelHold {
            try SharedModels.required().hold(of: IntegrationModels.toolCallingLLM)
        }

        /// Asks `prompt` in a new session, and then injects the result of each
        /// background run as a new message, the same as a real session. The
        /// host injects the result of a run after the run settles. It injects
        /// one message for each pending envelope that the model got, also for
        /// an envelope of a call that the model made after an injection.
        ///
        /// - Parameters:
        ///   - prompt: The request of the user.
        ///   - instructions: The instructions of the session.
        ///   - tools: The mounted tools of the session.
        ///   - host: The host of the session.
        ///   - hold: The hold of the tool-calling LLM.
        /// - Returns: The answer to the last message, with each tool output of
        ///   the session.
        /// - Throws: The error of a generation, or a failed expectation when a
        ///   run of an envelope does not settle.
        private static func answerInjectingSettledRuns(
            to prompt: String, instructions: String, tools: [any Tool], host: ToolHost, with hold: ModelHold
        ) async throws -> ToolSession.Answer {
            try await ToolSession.run(instructions: instructions, tools: tools, with: hold) { session in
                var answer = try await ToolSession.answer(to: prompt, in: session)
                var injected: Set<String> = []
                while let token = pendingTokens(in: answer).first(where: { !injected.contains($0) }) {
                    injected.insert(token)
                    let terminal = try await terminal(of: token, in: host)
                    answer = try await ToolSession.answer(
                        to: HostMessage.settledRun(completionToken: token, terminal: terminal), in: session)
                }
                return answer
            }
        }

        /// Checks the per-call claim on one answer: each run on the run plane
        /// came from a pending envelope and settles with `backgroundCode`, a
        /// tool output that is not an envelope holds `synchronousCode`, and
        /// the text of the answer holds `backgroundCode`, which only the
        /// injected result gave the model.
        ///
        /// - Parameters:
        ///   - answer: The last answer of the session.
        ///   - host: The host of the session.
        ///   - backgroundCode: The code that the result of the background call holds.
        ///   - synchronousCode: The code that the result of the synchronous call holds.
        /// - Throws: A failed expectation when a run of an envelope does not settle.
        private static func expectPerCallMounts(
            of answer: ToolSession.Answer, in host: ToolHost, backgroundCode: String, synchronousCode: String
        ) async throws {
            let pending = pendingTokens(in: answer)
            #expect(!pending.isEmpty, "tool outputs: \(answer.toolOutputs)")
            let inBand = answer.toolOutputs.filter { !PendingRunEnvelope.isRendered(text: $0) }
            #expect(inBand.contains { $0.contains(synchronousCode) }, "tool outputs: \(answer.toolOutputs)")
            for token in pending {
                let terminal = try await terminal(of: token, in: host)
                #expect(terminal.detail.contains(backgroundCode), "terminal: \(terminal)")
            }
            #expect(answer.text.contains(backgroundCode), "answer: \(answer.text)")
            // Only a background call is a run: the synchronous call started none.
            let open = await host.runPlane.backgroundRuns().map(\.completionToken)
            #expect(await host.runPlane.settledRunTokens().union(open) == Set(pending))
        }

        /// The completion token of each pending envelope of a session, in
        /// order.
        ///
        /// - Parameter answer: The answer of a session.
        /// - Returns: The completion tokens.
        private static func pendingTokens(in answer: ToolSession.Answer) -> [String] {
            envelopes(in: answer).filter(\.pending).map(\.completionToken)
        }

        /// The envelope of each tool output that is one, in order.
        ///
        /// - Parameter answer: The answer of a session.
        /// - Returns: The decoded envelopes.
        private static func envelopes(in answer: ToolSession.Answer) -> [PendingRunEnvelope] {
            answer.toolOutputs.compactMap(PendingRunEnvelope.makeDecoded(fromRendered:))
        }

        /// Whether `event` is the event that a background call posts with its
        /// pending envelope, before the call answers.
        ///
        /// - Parameter event: An event that a mounted tool posted.
        /// - Returns: `true` for a progress event whose detail is a rendered
        ///   envelope.
        @Sendable
        private static func isPendingEnvelope(_ event: OperationEvent) -> Bool {
            event.kind == .progress && PendingRunEnvelope.isRendered(text: event.detail)
        }

        /// Waits with no deadline for the run of `token`, and gives its
        /// terminal event. The wait ends when the run settles.
        ///
        /// - Parameters:
        ///   - token: The completion token of the run.
        ///   - host: The host of the session of the run.
        /// - Returns: The terminal event of the run.
        /// - Throws: A failed expectation when no run has `token`.
        private static func terminal(of token: String, in host: ToolHost) async throws -> OperationEvent {
            let outcome = await host.runPlane.wait(completionToken: token, seconds: nil)
            return try #require(outcome.settledTerminal, "the wait for \(token) gave \(outcome)")
        }
    }
}

extension WaitOutcome {
    /// The terminal event of a settled run, or `nil` for each other outcome.
    fileprivate var settledTerminal: OperationEvent? {
        if case .settled(let terminal) = self {
            return terminal
        }
        return nil
    }
}
