@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises ``ToolCallWitness``: a site with a witness reports the start of
/// each inner call that ``ToolContext/mount(_:op:as:)`` mounted, one time, and
/// never an outer call that the host mounted.
@Suite("ToolCallWitness: a site reports the start of each inner call that ToolContext.mount mounts")
struct ToolCallWitnessTests {
    private typealias Fixtures = MountFixtures

    /// A witness that keeps each reported call, in report order.
    struct RecordingWitness: ToolCallWitness {
        /// Each reported call, in report order.
        let calls = Recorder<WitnessedToolCall>()

        /// Each call that ended, with its result, in report order.
        let endedCalls = Recorder<EndedCall>()

        /// Keeps `call`.
        func toolCallWillBegin(_ call: WitnessedToolCall) {
            calls.append(call)
        }

        /// Keeps `call` and `result`.
        func toolCallDidEnd(_ call: WitnessedToolCall, result: OperationResult) {
            endedCalls.append(EndedCall(call: call, result: result))
        }
    }

    /// One call that ended, and its result.
    struct EndedCall: Sendable {
        /// The call.
        let call: WitnessedToolCall

        /// The final result of the call.
        let result: OperationResult
    }

    /// The exit code that the failing fixture tools report.
    private static let exitCode = 3

    /// The result of a call that reported ``exitCode``.
    private static let reportedResult = OperationResult(outcome: .failed, value: .int(exitCode))

    /// The result of a call that reported nothing and returned.
    private static let plainResult = OperationResult(outcome: .succeeded, value: nil)

    /// A tool that reports a failure with ``exitCode``, then returns its
    /// output. The output type tells the case: `String` gets a runner, any
    /// other output gets only a bound context.
    struct FailingTool<Output: FailingToolOutput>: Tool {
        let name = Output.toolName
        let description = Output.toolDescription

        func call(arguments: MountArguments) async throws -> Output {
            ToolContext.current?.reportFailure(value: .int(ToolCallWitnessTests.exitCode))
            return Output.failedOutput
        }
    }

    /// The shared throwing fixture, with an output that is not `String`.
    private static func throwingNonStringTool(
        throwing error: any Error
    ) -> Fixtures.ThrowingTool<MountArguments, NonStringToolOutput> {
        Fixtures.ThrowingTool(error: error)
    }

    /// An error that settles a run as lost.
    struct DroppedTransport: LostRunError {}

    /// An error that a tool throws, and the outcome that the end of its call
    /// has to carry.
    struct ThrownCase: Sendable, CustomTestStringConvertible {
        /// What the case tells.
        let testDescription: String

        /// The error that the tool throws.
        let error: any Error

        /// The outcome of the end of the call.
        let outcome: OperationOutcome
    }

    /// Each kind of error that ``OperationOutcome/init(thrown:)`` tells apart.
    private static let thrownCases = [
        ThrownCase(testDescription: "a cancel", error: CancellationError(), outcome: .cancelled),
        ThrownCase(
            testDescription: "a timeout", error: ToolMountError.timedOut(tool: "t", timeoutSeconds: 1),
            outcome: .timedOut),
        ThrownCase(testDescription: "a lost run", error: DroppedTransport(), outcome: .lost),
        ThrownCase(testDescription: "any other error", error: Fixtures.FixtureError(), outcome: .failed),
    ]

    /// An outer tool whose body makes its inner calls through the context of
    /// its own call.
    struct MountingTool: Tool {
        /// The name of each mounting tool.
        static let toolName = "mounting_tool"

        let name = toolName
        let description = "makes inner calls through ToolContext.mount"

        /// The body of each call, with the context of the call.
        let body: @Sendable (ToolContext) async throws -> String

        func call(arguments: MountArguments) async throws -> String {
            try await body(try #require(ToolContext.current))
        }
    }

    /// The value of each inner call.
    private static let innerValue = "inner"

    /// The value of each outer call.
    private static let outerValue = "outer"

    /// The op of the inner mounts that state one.
    private static let innerOp = "run fast"

    /// The arguments of each inner call.
    private static let innerArguments = MountArguments(value: innerValue)

    /// A root session: its id, its run plane, its sink, its witness and its
    /// mount site.
    private struct Session {
        let sessionID = ULID()
        let runPlane = RunPlane()
        let sink = Fixtures.RecordingSink()
        let witness = RecordingWitness()
        let site: MountSite

        /// Makes the session.
        ///
        /// - Parameter isWitnessed: Whether the site carries ``witness``.
        init(isWitnessed: Bool = true) {
            site = MountSite(
                sessionID: sessionID, runPlane: runPlane, sink: sink,
                inlineSettleGrace: Fixtures.pendingAtOnceGrace, callWitness: isWitnessed ? witness : nil)
        }

        /// The result of each call that ended, in report order.
        var endedResults: [OperationResult] { witness.endedCalls.values.map(\.result) }

        /// The tool name of each reported call, in report order.
        var reportedTools: [String] { witness.calls.values.map(\.tool) }

        /// Mounts a ``MountingTool`` with `body` on the site, as a host does,
        /// and makes one outer call of it.
        ///
        /// - Parameter body: The body of the outer call.
        /// - Returns: The output of the outer call.
        func callOuter(_ body: @escaping @Sendable (ToolContext) async throws -> String) async throws -> String {
            try await Self.call(MountingTool(body: body), on: site)
        }

        /// Mounts `tool` in the background through an outer call, and waits for
        /// its run to settle.
        ///
        /// - Parameter tool: The tool to run.
        /// - Returns: The envelope that the outer call returned.
        func runBackgroundCall(of tool: some Tool<MountArguments, String>) async throws -> Fixtures.DecodedEnvelope {
            let rendered = try await callOuter { context in
                try await context.mount(tool, as: ToolMount(mode: .background))
                    .call(arguments: ToolCallWitnessTests.innerArguments)
            }
            let envelope = try Fixtures.decodeEnvelope(rendered)
            _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: runPlane)
            return envelope
        }

        /// Mounts `tool` on `site`, as a host does, and makes one call of it.
        ///
        /// - Parameters:
        ///   - tool: The tool to mount.
        ///   - site: Where the tool runs.
        /// - Returns: The output of the call.
        static func call(_ tool: any Tool, on site: MountSite) async throws -> String {
            let mounted = try #require(
                ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous)
                    as? any Tool<MountArguments, String>)
            return try await mounted.call(arguments: MountArguments(value: outerValue))
        }
    }

    /// Mounts ``MountFixtures/FastTool`` through `context` with `op`, and calls
    /// it with ``innerArguments``.
    private static func callFastTool(through context: ToolContext, op: String? = innerOp) async throws -> String {
        try await context.mount(Fixtures.FastTool(), op: op).call(arguments: innerArguments)
    }

    // MARK: - Outer calls

    @Test("an outer call on a site with a witness gives no report")
    func anOuterCallIsNotReported() async throws {
        let session = Session()

        let output = try await session.callOuter { _ in Self.outerValue }

        #expect(output == Self.outerValue)
        #expect(session.reportedTools.isEmpty)
    }

    // MARK: - Inner calls

    @Test("an inner call through mount(_:op:as:) gives one report with its tool, op, arguments and session")
    func anInnerCallIsReportedOnce() async throws {
        let session = Session()

        let output = try await session.callOuter { try await Self.callFastTool(through: $0) }

        #expect(output == "fast: \(Self.innerValue)")
        #expect(session.reportedTools == [Fixtures.FastTool().name])
        let call = try #require(session.witness.calls.values.first)
        #expect(call.op == Self.innerOp)
        #expect(call.arguments == Self.innerArguments.generatedContent)
        #expect(call.sessionID == session.sessionID)
    }

    @Test("an inner mount with no op reports the tool name as the op")
    func anInnerCallWithNoOpReportsTheToolName() async throws {
        let session = Session()

        _ = try await session.callOuter { try await Self.callFastTool(through: $0, op: nil) }

        #expect(session.witness.calls.values.map(\.op) == [Fixtures.FastTool().name])
    }

    @Test("an inner call through mount(_:op:as:postingTo:) gives one report")
    func anInnerCallPostingToASinkIsReported() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(Fixtures.FastTool(), op: Self.innerOp, postingTo: Fixtures.RecordingSink())
                .call(arguments: Self.innerArguments)
        }

        #expect(session.reportedTools == [Fixtures.FastTool().name])
        #expect(session.witness.calls.values.map(\.op) == [Self.innerOp])
    }

    @Test("an inner run-to-completion call gives one report")
    func anInnerRunToCompletionCallIsReportedOnce() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(Fixtures.FastTool(), as: ToolMount(mode: .runToCompletion))
                .call(arguments: Self.innerArguments)
        }

        #expect(session.reportedTools == [Fixtures.FastTool().name])
    }

    @Test("an inner background call gives one report")
    func anInnerBackgroundCallIsReportedOnce() async throws {
        let session = Session()

        _ = try await session.runBackgroundCall(of: Fixtures.FastTool())

        #expect(session.reportedTools == [Fixtures.FastTool().name])
    }

    @Test("an inner call of a tool whose output is not String gives one report")
    func anInnerNonStringCallIsReportedOnce() async throws {
        let session = Session()

        let output = try await session.callOuter { context in
            try await context.mount(Fixtures.NonStringOutputTool()).call(arguments: Self.innerArguments).text
        }

        #expect(output == "ignored")
        #expect(session.reportedTools == [Fixtures.NonStringOutputTool().name])
        #expect(session.witness.calls.values.map(\.arguments) == [Self.innerArguments.generatedContent])
    }

    @Test("two inner calls give two reports, in call order")
    func twoInnerCallsAreReportedInOrder() async throws {
        let session = Session()
        let firstOp = "first op"
        let secondOp = "second op"

        _ = try await session.callOuter { context in
            _ = try await Self.callFastTool(through: context, op: firstOp)
            return try await Self.callFastTool(through: context, op: secondOp)
        }

        #expect(session.witness.calls.values.map(\.op) == [firstOp, secondOp])
    }

    @Test("an inner call of an inner call is reported after the inner call that makes it")
    func anInnerCallOfAnInnerCallIsReported() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(MountingTool { try await Self.callFastTool(through: $0) })
                .call(arguments: Self.innerArguments)
        }

        #expect(session.reportedTools == [MountingTool.toolName, Fixtures.FastTool().name])
    }

    @Test("an inner tool that throws gives one report, and its error is unchanged")
    func aThrowingInnerCallIsReportedOnce() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            await #expect(throws: Fixtures.FixtureError()) {
                try await context.mount(Fixtures.ThrowingTool<MountArguments, String>()).call(arguments: Self.innerArguments)
            }
            return Self.outerValue
        }

        #expect(session.reportedTools == [Fixtures.ThrowingTool<MountArguments, String>().name])
    }

    // MARK: - The end of a call

    @Test("an inner call that reports a failure ends with the failed result and its value")
    func anInnerReportedFailureEndsWithTheResult() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(FailingTool<String>()).call(arguments: Self.innerArguments)
        }

        let ended = try #require(session.witness.endedCalls.values.first)
        #expect(ended.call.tool == FailingTool<String>().name)
        #expect(ended.result == Self.reportedResult)
    }

    @Test("an inner call that reports nothing ends with a succeeded result and no value")
    func anInnerPlainCallEndsSucceeded() async throws {
        let session = Session()

        _ = try await session.callOuter { try await Self.callFastTool(through: $0) }

        #expect(session.endedResults.first == Self.plainResult)
    }

    @Test("an inner call that throws ends with a failed result and no value")
    func anInnerThrowEndsFailed() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            _ = try? await context.mount(Fixtures.ThrowingTool<MountArguments, String>()).call(arguments: Self.innerArguments)
            return Self.outerValue
        }

        #expect(session.endedResults.first == OperationResult(outcome: .failed, value: nil))
    }

    @Test("an inner call of a tool whose output is not String ends with the reported failure")
    func anInnerNonStringCallEndsWithTheResult() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(FailingTool<NonStringToolOutput>()).call(arguments: Self.innerArguments).text
        }

        #expect(session.endedResults.first == Self.reportedResult)
    }

    @Test("an inner call of a tool whose output is not String ends with the outcome of the error that it threw",
          arguments: ToolCallWitnessTests.thrownCases)
    func anInnerNonStringThrowEndsWithTheOutcomeOfTheError(thrown: ThrownCase) async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            _ = try? await context.mount(Self.throwingNonStringTool(throwing: thrown.error))
                .call(arguments: Self.innerArguments)
            return Self.outerValue
        }

        let ended = try #require(
            session.witness.endedCalls.values.first { $0.call.tool == Self.throwingNonStringTool(throwing: thrown.error).name })
        #expect(ended.result == OperationResult(outcome: thrown.outcome, value: nil))
    }

    @Test("an inner background call ends with its result when its run settles")
    func anInnerBackgroundCallEndsWithTheResult() async throws {
        let session = Session()

        _ = try await session.runBackgroundCall(of: FailingTool<String>())
        // The end of the run goes to the witness after the run settles.
        await session.witness.endedCalls.waitUntil { $0.contains { $0.result == Self.reportedResult } }

        #expect(session.endedResults.contains(Self.reportedResult))
    }

    @Test("an outer call ends with its result, after the inner call that it makes")
    func anOuterCallEndsAfterItsInnerCall() async throws {
        let session = Session()

        _ = try await session.callOuter { try await Self.callFastTool(through: $0) }

        #expect(session.witness.endedCalls.values.map(\.call.tool) == [Fixtures.FastTool().name, MountingTool.toolName])
        #expect(session.endedResults == [Self.plainResult, Self.plainResult])
    }

    @Test("an outer call that reports a failure ends with the failed result and its value")
    func anOuterReportedFailureEndsWithTheResult() async throws {
        let session = Session()

        let output = try await Session.call(FailingTool<String>(), on: session.site)

        #expect(output == "failed output")
        #expect(session.endedResults == [Self.reportedResult])
    }

    @Test("an outer call keeps no begin report, though it gets an end report")
    func anOuterCallGetsOnlyTheEnd() async throws {
        let session = Session()

        _ = try await session.callOuter { _ in Self.outerValue }

        #expect(session.reportedTools.isEmpty)
        #expect(session.endedResults.count == 1)
    }

    @Test("the start and the end of an inner call give the same correlation ID")
    func anInnerCallStartAndEndShareACorrelationID() async throws {
        let session = Session()

        _ = try await session.callOuter { try await Self.callFastTool(through: $0) }

        let started = try #require(session.witness.calls.values.first?.correlationID)
        let ended = try #require(session.witness.endedCalls.values.first?.call.correlationID)
        #expect(started == ended)
    }

    @Test("the start and the end of an inner background call give the same correlation ID")
    func aBackgroundCallStartAndEndShareACorrelationID() async throws {
        let session = Session()

        let envelope = try await session.runBackgroundCall(of: FailingTool<String>())
        await session.witness.endedCalls.waitUntil { $0.contains { $0.call.tool == FailingTool<String>().name } }

        let ended = try #require(session.witness.endedCalls.values.first { $0.call.tool == FailingTool<String>().name })
        #expect(session.witness.calls.values.first?.correlationID == envelope.completionToken)
        #expect(ended.call.correlationID == envelope.completionToken)
    }

    @Test("the start and the end of an inner call of a tool whose output is not String share a correlation ID")
    func aNonStringCallStartAndEndShareACorrelationID() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(FailingTool<NonStringToolOutput>()).call(arguments: Self.innerArguments).text
        }

        let started = try #require(session.witness.calls.values.first?.correlationID)
        let ended = try #require(
            session.witness.endedCalls.values.first { $0.call.tool == FailingTool<NonStringToolOutput>().name }?.call.correlationID)
        #expect(started == ended)
    }

    @Test("an outer call on a site with a witness reaches the end with a correlation ID")
    func anOuterCallEndHasACorrelationID() async throws {
        let session = Session()

        _ = try await session.callOuter { _ in Self.outerValue }

        let ended = try #require(session.witness.endedCalls.values.first)
        #expect(ended.call.tool == MountingTool.toolName)
        #expect(ended.call.correlationID != nil)
    }

    @Test("a site with no witness gives no end report")
    func aSiteWithNoWitnessGivesNoEnd() async throws {
        let session = Session(isWitnessed: false)

        _ = try await session.callOuter { try await Self.callFastTool(through: $0) }

        #expect(session.endedResults.isEmpty)
    }

    // MARK: - Sites with no witness

    @Test("the site of a child session drops the witness, so its inner calls give no report")
    func aChildSiteGivesNoReport() async throws {
        let session = Session()

        let output = try await session.callOuter { context in
            let childID = ULID()
            let childSite = context.childSite(
                sessionID: childID, runPlane: RunPlane(workRegistry: WorkRegistry(sessionID: childID)),
                sink: Fixtures.RecordingSink())
            return try await Session.call(MountingTool { try await Self.callFastTool(through: $0) }, on: childSite)
        }

        #expect(output == "fast: \(Self.innerValue)")
        #expect(session.reportedTools.isEmpty)
    }

    @Test("a site with no witness gives the same output and the same events as a site with one")
    func aSiteWithNoWitnessChangesNothing() async throws {
        let witnessed = Session()
        let unwitnessed = Session(isWitnessed: false)

        let witnessedOutput = try await witnessed.callOuter { try await Self.callFastTool(through: $0) }
        let unwitnessedOutput = try await unwitnessed.callOuter { try await Self.callFastTool(through: $0) }

        #expect(unwitnessedOutput == witnessedOutput)
        #expect(await unwitnessed.sink.events.map(\.kind) == witnessed.sink.events.map(\.kind))
        #expect(unwitnessed.reportedTools.isEmpty)
    }
}

/// The output of a ``ToolCallWitnessTests/FailingTool``, with the name and the description that
/// tell its case.
protocol FailingToolOutput: PromptRepresentable, Sendable {
    /// The name of the tool of this output.
    static var toolName: String { get }

    /// The description of the tool of this output.
    static var toolDescription: String { get }

    /// The output that the tool returns after it reports its failure.
    static var failedOutput: Self { get }
}

extension String: FailingToolOutput {
    static var toolName: String { "failing_tool" }
    static var toolDescription: String { "reports a failure with an exit code, then returns" }
    static var failedOutput: String { "failed output" }
}

extension NonStringToolOutput: FailingToolOutput {
    static var toolName: String { "failing_non_string_tool" }
    static var toolDescription: String { "reports a failure, then returns a non-String output" }
    static var failedOutput: NonStringToolOutput { NonStringToolOutput(text: "failed output") }
}
