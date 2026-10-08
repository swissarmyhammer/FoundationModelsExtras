import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

/// The timeout of the mount of ``StuckRecordTool``, in seconds. The tool works
/// much longer than this time.
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
    /// background call and one synchronous call, and collect the background
    /// result with the wait tool.
    ///
    /// - Parameters:
    ///   - backgroundCall: How the model makes the background call.
    ///   - synchronousCall: How the model makes the synchronous call.
    /// - Returns: The instructions.
    static func callingBoth(backgroundCall: String, synchronousCall: String) -> String {
        "You are a helpful assistant. To answer the user, first \(backgroundCall). Then \(synchronousCall). "
            + "When a tool result says that a run continues in the background, call the wait tool with its "
            + "completionToken. Then reply with both results, word for word."
    }
}

extension RealModelSuites {
    /// Tool hosting under a real FoundationModels session: the model calls
    /// mounted tools, and the run plane runs and settles the background runs.
    @Suite("Tool hosting with a real model", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct ToolHostingIntegrationTests {
        @Test("an in-band tool reads its context, posts progress, and the answer of the model holds its result")
        func inBandToolRunsToCompletion() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let host = ToolHost()
            let readings = EventLog<ContextReading>()
            let tool = VaultCodeTool(readings: readings)

            let answer = try await ToolSession.answer(
                to: "What is the code of the vault named north?", instructions: SessionInstructions.callingOnce(tool.name),
                tools: [host.mount(tool)], in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

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
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            // The scan works for a short time, so the host states grace 0:
            // the call answers with the pending envelope at once.
            let host = ToolHost(inlineSettleGrace: pendingAtOnceGrace)
            let settlements = EventLog<OperationEvent>()
            await host.runPlane.attach(settlementObserver: settlements)
            let tool = ArchiveScanTool()

            let answer = try await ToolSession.answer(
                to: "Start a scan of the archive named west.", instructions: SessionInstructions.callingOnce(tool.name),
                tools: [host.mount(tool)], in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

            let envelope = try #require(Self.envelopes(in: answer).first, "tool outputs: \(answer.toolOutputs)")
            #expect(envelope.pending)
            #expect(!answer.text.contains(ArchiveScanTool.code), "answer: \(answer.text)")
            let terminal = try await Self.terminal(of: envelope.completionToken, in: host)
            #expect(terminal.outcome == .succeeded)
            #expect(terminal.detail == ArchiveScanTool.report)
            try await Waiting.until { await !settlements.events.isEmpty }
            #expect(await settlements.events == [terminal])
        }

        @Test("a background run that ends inside the default settle period gives the model its own output, with no envelope")
        func fastBackgroundRunAnswersInsideTheGrace() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            // The host takes the default settle period.
            let host = ToolHost()
            let tool = QuickScanTool()

            let answer = try await ToolSession.answer(
                to: "Scan the small archive named east, and tell me its report code.",
                instructions: SessionInstructions.callingOnce(tool.name), tools: [host.mount(tool)], in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

            #expect(answer.toolOutputs.contains(QuickScanTool.report), "tool outputs: \(answer.toolOutputs)")
            #expect(Self.envelopes(in: answer).isEmpty, "tool outputs: \(answer.toolOutputs)")
            #expect(answer.text.contains(QuickScanTool.code), "answer: \(answer.text)")
        }

        @Test("a cancel of a running background run gives the outcome of the canceler, and the run settles with that outcome")
        func cancelSettlesTheRunWithTheCancelerOutcome() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            // Grace 0: the call answers at once, and the test does not wait
            // for the settle period of a run that never ends by itself.
            let host = ToolHost(inlineSettleGrace: pendingAtOnceGrace)
            let tool = EndlessScanTool()

            let answer = try await ToolSession.answer(
                to: "Start a full scan of the archive named south.", instructions: SessionInstructions.callingOnce(tool.name),
                tools: [host.mount(tool)], in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

            let envelope = try #require(Self.envelopes(in: answer).first, "tool outputs: \(answer.toolOutputs)")
            #expect(envelope.pending)
            #expect(await host.runPlane.backgroundRuns().contains { $0.completionToken == envelope.completionToken })
            #expect(await host.cancel(completionToken: envelope.completionToken) == .reported(.cancelled))
            let terminal = try await Self.terminal(of: envelope.completionToken, in: host)
            #expect(terminal.outcome == .cancelled)
        }

        @Test("a tool that ignores the cancel past its timeout gives the model the timeout failure, and the model call returns")
        func timeoutReachesTheModelAndTheCallReturns() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let host = ToolHost()
            let tool = StuckRecordTool()
            let mounted = host.mount(tool, as: ToolMount(mode: .runToCompletion, timeout: stuckToolTimeoutSeconds))

            let (answer, duration) = try await ToolSession.run(
                instructions: SessionInstructions.callingOnce(tool.name), tools: [mounted], in: pool
            ) { session in
                let start = ContinuousClock.now
                let answer = try await ToolSession.answer(to: "Look up the record named alpha.", in: session)
                return (answer, start.duration(to: .now))
            }
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

            let timedOut = ToolMountError.timedOut(tool: tool.name, timeoutSeconds: stuckToolTimeoutSeconds).description
            #expect(answer.toolOutputs.contains(timedOut), "tool outputs: \(answer.toolOutputs)")
            #expect(duration < .seconds(StuckRecordTool.workSeconds), "the model call took \(duration)")
            #expect(await host.events.events.contains { $0.kind == .completed && $0.outcome == .timedOut })
        }

        @Test("a tool that throws gives the model a failure result, not a thrown error, and the session continues")
        func failureReachesTheModelAsAResult() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let host = ToolHost()
            let tool = LockedArchiveTool()
            let archive = "north"

            let (first, followUp) = try await ToolSession.run(
                instructions: SessionInstructions.callingOnce(tool.name), tools: [host.mount(tool)], in: pool
            ) { session in
                let first = try await ToolSession.answer(to: "Open the archive named \(archive).", in: session)
                let followUp = try await ToolSession.answer(
                    to: "What error code did the tool give? Reply with the error code only.", in: session)
                return (first, followUp.text)
            }
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

            let failureText = ArchiveLockedError(archive: archive).description
            #expect(first.toolOutputs.contains(failureText), "tool outputs: \(first.toolOutputs)")
            #expect(followUp.contains(ArchiveLockedError.code), "follow-up answer: \(followUp)")
            #expect(await host.events.events.contains { $0.kind == .completed && $0.outcome == .failed })
        }

        @Test("one tool gives the model a pending token for its background call and the real result in band for its synchronous call")
        func perCallMountOfOneTool() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            // The scan job ends at once, so the host states grace 0: the
            // background call answers with the pending envelope at once.
            let host = ToolHost(inlineSettleGrace: pendingAtOnceGrace)
            let tool = JobTool()
            let instructions = SessionInstructions.callingBoth(
                backgroundCall: "call the \(tool.name) tool with job \"\(JobTool.scanJob)\"",
                synchronousCall: "call the \(tool.name) tool with job \"\(JobTool.countJob)\"")

            let answer = try await ToolSession.answer(
                to: "Run the scan job and the count job, and tell me both results.", instructions: instructions,
                tools: [host.mount(tool), host.mount(WaitTool())], in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

            try await Self.expectPerCallMounts(
                of: answer, in: host, backgroundResult: JobTool.scanResult, synchronousResult: JobTool.countResult)
        }

        @Test("an operation tool gives the model a pending token for its background operation and the real result in band for its synchronous operation")
        func perCallMountOfAnOperationTool() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            // The scan operation ends at once, so the host states grace 0:
            // the background call answers with the pending envelope at once.
            let host = ToolHost(inlineSettleGrace: pendingAtOnceGrace)
            let tool = try ArchiveOperationTool.make()
            let instructions = SessionInstructions.callingBoth(
                backgroundCall: "call the \(tool.name) tool with op \"\(StartScanOperation.opString)\"",
                synchronousCall: "call the \(tool.name) tool with op \"\(CountFilesOperation.opString)\"")

            let answer = try await ToolSession.answer(
                to: "Start a scan of the archive and count its files, and tell me both report codes.",
                instructions: instructions, tools: [host.mount(tool), host.mount(WaitTool())], in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.toolCallingLLM, in: pool)

            try await Self.expectPerCallMounts(
                of: answer, in: host, backgroundResult: StartScanOperation.code, synchronousResult: CountFilesOperation.code)
        }

        /// Checks the per-call claim on one answer: each run on the run plane
        /// came from a pending envelope and settles with `backgroundResult`,
        /// and a tool output that is not an envelope holds `synchronousResult`.
        ///
        /// - Parameters:
        ///   - answer: The answer of the session.
        ///   - host: The host of the session.
        ///   - backgroundResult: A text that the result of the background call holds.
        ///   - synchronousResult: A text that the result of the synchronous call holds.
        /// - Throws: A failed expectation when the model got no pending envelope.
        private static func expectPerCallMounts(
            of answer: ToolSession.Answer, in host: ToolHost, backgroundResult: String, synchronousResult: String
        ) async throws {
            let pending = envelopes(in: answer).filter(\.pending).map(\.completionToken)
            #expect(!pending.isEmpty, "tool outputs: \(answer.toolOutputs)")
            let inBand = answer.toolOutputs.filter { !PendingRunEnvelope.isRendered(text: $0) }
            #expect(inBand.contains { $0.contains(synchronousResult) }, "tool outputs: \(answer.toolOutputs)")
            for token in pending {
                let terminal = try await terminal(of: token, in: host)
                #expect(terminal.detail.contains(backgroundResult), "terminal: \(terminal)")
            }
            // Only a background call is a run: the synchronous call started none.
            let open = await host.runPlane.backgroundRuns().map(\.completionToken)
            #expect(await host.runPlane.settledRunTokens().union(open) == Set(pending))
        }

        /// The envelope of each tool output that is one, in order.
        ///
        /// - Parameter answer: The answer of a session.
        /// - Returns: The decoded envelopes.
        private static func envelopes(in answer: ToolSession.Answer) -> [PendingRunEnvelope] {
            answer.toolOutputs.compactMap(PendingRunEnvelope.makeDecoded(fromRendered:))
        }

        /// Waits with no deadline for the run of `token`, and gives its
        /// terminal event. The time limit of the suite stops a wait that never
        /// ends.
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
