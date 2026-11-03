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

    /// A `String` tool that reports a failure with ``exitCode``, then returns.
    struct FailingTool: Tool {
        let name = "failing_tool"
        let description = "reports a failure with an exit code, then returns"

        func call(arguments: MountArguments) async throws -> String {
            ToolContext.current?.reportFailure(value: .int(ToolCallWitnessTests.exitCode))
            return "failed output"
        }
    }

    /// A tool whose output is not `String`. It reports a failure with
    /// ``exitCode``, then returns.
    struct FailingNonStringTool: Tool {
        let name = "failing_non_string_tool"
        let description = "reports a failure, then returns a non-String output"

        func call(arguments: MountArguments) async throws -> NonStringToolOutput {
            ToolContext.current?.reportFailure(value: .int(ToolCallWitnessTests.exitCode))
            return NonStringToolOutput(text: "failed output")
        }
    }

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

        let rendered = try await session.callOuter { context in
            try await context.mount(Fixtures.FastTool(), as: ToolMount(mode: .background))
                .call(arguments: Self.innerArguments)
        }
        let envelope = try Fixtures.decodeEnvelope(rendered)
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)

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
                try await context.mount(Fixtures.ThrowingTool()).call(arguments: Self.innerArguments)
            }
            return Self.outerValue
        }

        #expect(session.reportedTools == [Fixtures.ThrowingTool().name])
    }

    // MARK: - The end of a call

    @Test("an inner call that reports a failure ends with the failed result and its value")
    func anInnerReportedFailureEndsWithTheResult() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(FailingTool()).call(arguments: Self.innerArguments)
        }

        let ended = try #require(session.witness.endedCalls.values.first)
        #expect(ended.call.tool == FailingTool().name)
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
            _ = try? await context.mount(Fixtures.ThrowingTool()).call(arguments: Self.innerArguments)
            return Self.outerValue
        }

        #expect(session.endedResults.first == OperationResult(outcome: .failed, value: nil))
    }

    @Test("an inner call of a tool whose output is not String ends with the reported failure")
    func anInnerNonStringCallEndsWithTheResult() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(FailingNonStringTool()).call(arguments: Self.innerArguments).text
        }

        #expect(session.endedResults.first == Self.reportedResult)
    }

    @Test("an inner background call ends with its result when its run settles")
    func anInnerBackgroundCallEndsWithTheResult() async throws {
        let session = Session()

        let rendered = try await session.callOuter { context in
            try await context.mount(FailingTool(), as: ToolMount(mode: .background))
                .call(arguments: Self.innerArguments)
        }
        let envelope = try Fixtures.decodeEnvelope(rendered)
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
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

        let output = try await Session.call(FailingTool(), on: session.site)

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

        let rendered = try await session.callOuter { context in
            try await context.mount(FailingTool(), as: ToolMount(mode: .background))
                .call(arguments: Self.innerArguments)
        }
        let envelope = try Fixtures.decodeEnvelope(rendered)
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
        await session.witness.endedCalls.waitUntil { $0.contains { $0.call.tool == FailingTool().name } }

        let ended = try #require(session.witness.endedCalls.values.first { $0.call.tool == FailingTool().name })
        #expect(session.witness.calls.values.first?.correlationID == envelope.completionToken)
        #expect(ended.call.correlationID == envelope.completionToken)
    }

    @Test("the start and the end of an inner call of a tool whose output is not String share a correlation ID")
    func aNonStringCallStartAndEndShareACorrelationID() async throws {
        let session = Session()

        _ = try await session.callOuter { context in
            try await context.mount(FailingNonStringTool()).call(arguments: Self.innerArguments).text
        }

        let started = try #require(session.witness.calls.values.first?.correlationID)
        let ended = try #require(
            session.witness.endedCalls.values.first { $0.call.tool == FailingNonStringTool().name }?.call.correlationID)
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
