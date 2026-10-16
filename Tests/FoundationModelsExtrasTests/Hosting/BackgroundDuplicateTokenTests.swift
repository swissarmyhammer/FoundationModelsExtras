@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import TelemetryTestSupport
import Testing
import ULID

/// Exercises a background call whose run the run plane refuses, because a
/// different run already has its completion token, and the gate that holds
/// the body of a run until the call posted its open record and its envelope.
///
/// A run plane with a token source that gives one token for each run makes
/// two calls ask for the same token. Each wait reads the run plane or a gate
/// that a step of the test opens. No test reads a clock, sleeps, polls or
/// retries.
@Suite("BackgroundToolRunner: a refused run token, and the gate of the body")
struct BackgroundDuplicateTokenTests {
    private typealias Fixtures = MountFixtures

    /// A sink that keeps each event and each invocation record, in post
    /// order.
    private actor RecordSink: OperationEventSink {
        /// Each event, in post order.
        private(set) var events: [OperationEvent] = []

        /// Each open and close record, in post order.
        private(set) var records: [ToolInvocationRecord] = []

        /// Keeps `event`.
        ///
        /// - Parameter event: The event.
        func post(event: OperationEvent) {
            events.append(event)
        }

        /// Keeps `record`.
        ///
        /// - Parameter record: The record.
        func post(invocation record: ToolInvocationRecord) {
            records.append(record)
        }
    }

    /// Counts each call of its body, and returns at once.
    private struct CountingTool: Tool {
        let name = "counting_tool"
        let description = "counts each call and returns at once"

        /// Gets one value for each call of the body.
        let calls: Recorder<String>

        func call(arguments: MountArguments) async throws -> String {
            calls.append(arguments.value)
            return "counted: \(arguments.value)"
        }
    }

    /// A run plane whose runs all get `token`.
    ///
    /// - Parameter token: The token of each run.
    /// - Returns: The run plane.
    private static func runPlane(givingEachRun token: String) -> RunPlane {
        RunPlane(clock: ContinuousRunClock(), userPresence: .interactive, tokenSource: { token })
    }

    /// `tool` in a background mount on `runPlane` and `sink`, with a settle
    /// period of 0, so that each call answers at once.
    ///
    /// - Parameters:
    ///   - tool: The tool.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the session.
    /// - Returns: The mounted tool.
    private static func mounted(
        _ tool: any Tool<MountArguments, String>, on runPlane: RunPlane, sink: RecordSink
    ) -> BackgroundToolRunner<MountArguments> {
        BackgroundToolRunner(
            wrapping: tool, site: Fixtures.site(runPlane: runPlane, sink: sink, inlineSettleGrace: 0), timeout: nil)
    }

    @Test("a second call with the token of an open run gets the error, its body never runs, it posts nothing, and it logs one error")
    func aDuplicateTokenFailsSafely() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let token = RunPlane.makeCompletionToken()
            let runPlane = Self.runPlane(givingEachRun: token)
            let sink = RecordSink()
            let gate = RunLatch()
            let calls = Recorder<String>()
            let first = Self.mounted(Fixtures.GatedTool(gate: gate), on: runPlane, sink: sink)
            let second = Self.mounted(CountingTool(calls: calls), on: runPlane, sink: sink)

            let envelope = try Fixtures.decodeEnvelope(await first.call(arguments: MountArguments(value: "first")))
            let eventsBefore = await sink.events
            let recordsBefore = await sink.records
            let expected = DuplicateRunTokenError(completionToken: token, tool: "counting_tool").description
            await #expect {
                _ = try await second.call(arguments: MountArguments(value: "second"))
            } throws: { error in
                error is DuplicateRunTokenError && "\(error)" == expected
            }
            #expect(await sink.events == eventsBefore)
            #expect(await sink.records == recordsBefore)
            #expect(context.logRecords.filter { $0.level == .error && "\($0.message)" == expected }.count == 1)

            gate.open()
            let terminal = try #require(await runPlane.wait(completionToken: token, seconds: nil).settledTerminal)

            #expect(envelope.completionToken == token)
            #expect(terminal.outcome == .succeeded)
            #expect(terminal.detail == "gated: first")
            #expect(calls.values.isEmpty)
            #expect(await sink.records.count == 2)
            #expect(await runPlane.backgroundRuns().isEmpty)
        }
    }

    @Test("the body of a run starts its work only after the call posted its open record and its envelope")
    func theBodyRunsAfterTheOpenRecordAndTheEnvelope() async throws {
        let runPlane = RunPlane()
        let sink = RecordSink()
        let calls = Recorder<String>()
        let mounted = Self.mounted(CountingTool(calls: calls), on: runPlane, sink: sink)

        let envelope = try Fixtures.decodeEnvelope(await mounted.call(arguments: MountArguments(value: "x")))
        let terminal = try #require(
            await runPlane.wait(completionToken: envelope.completionToken, seconds: nil).settledTerminal)

        let events = await sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.first.map { PendingRunEnvelope.isRendered(text: $0.detail) } == true)
        #expect(terminal.detail == "counted: x")
        #expect(await sink.records.count == 2)
        #expect(calls.values == ["x"])
    }

    @Test("the envelope of a call does not go into the progress detail of its run on the run plane")
    func theEnvelopeIsNotTheProgressOfTheRun() async throws {
        let runPlane = RunPlane()
        let sink = RecordSink()
        let gate = RunLatch()
        let mounted = Self.mounted(Fixtures.GatedTool(gate: gate), on: runPlane, sink: sink)

        let envelope = try Fixtures.decodeEnvelope(await mounted.call(arguments: MountArguments(value: "x")))
        let rows = await runPlane.backgroundRuns()
        gate.open()
        _ = await runPlane.wait(completionToken: envelope.completionToken, seconds: nil)

        #expect(rows.map(\.completionToken) == [envelope.completionToken])
        #expect(rows.first?.latestProgressDetail == nil)
        #expect(await sink.events.first?.kind == .progress)
    }

    @Test("a call whose task is cancelled before the gate opens still lets the body run, and no run stays open")
    func aCancelBeforeTheGateOpensLetsTheBodySettle() async throws {
        let token = RunPlane.makeCompletionToken()
        let runPlane = Self.runPlane(givingEachRun: token)
        let sink = RecordSink()
        let calls = Recorder<String>()
        let mounted = Self.mounted(CountingTool(calls: calls), on: runPlane, sink: sink)
        let callStarts = RunLatch.closed()

        let calling = Task {
            await callStarts.waitUntilOpen()
            return try await mounted.call(arguments: MountArguments(value: "cancelled"))
        }
        calling.cancel()
        callStarts.open()
        _ = await calling.result
        let terminal = try #require(await runPlane.wait(completionToken: token, seconds: nil).settledTerminal)

        #expect(terminal.detail == "counted: cancelled")
        #expect(calls.values == ["cancelled"])
        #expect(await runPlane.backgroundRuns().isEmpty)
    }
}
