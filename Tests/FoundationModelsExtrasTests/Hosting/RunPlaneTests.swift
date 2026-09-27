@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing

/// Exercises the ``RunKind`` words: the raw value of each kind, what an
/// unknown raw value does, and the authority that a kind gives the canceler of
/// a run.
@Suite("Run plane: the run kinds and the cancellation authority of each")
struct RunPlaneTests {
    // MARK: - rawValue

    @Test(arguments: [(RunKind.swiftTask, "swiftTask"), (RunKind.process, "process")])
    func rawValueNamesTheKind(kind: RunKind, expected: String) {
        #expect(kind.rawValue == expected)
    }

    @Test func codableRoundTripPreservesEveryKind() throws {
        for kind in [RunKind.swiftTask, .process] {
            let data = try JSONEncoder().encode(kind)

            #expect(try JSONDecoder().decode(RunKind.self, from: data) == kind)
        }
    }

    @Test func decodingAnUnrecognizedRawValueThrowsRatherThanCrashing() {
        let data = Data("\"mcpRequest\"".utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RunKind.self, from: data)
        }
    }

    // MARK: - A process run

    @Test("a process run is listed under that kind, and cancel() reports the .stopped of its canceler")
    func processRunIsListedAndCancelReportsStopped() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch, kind: .process, cancelerOutcome: .stopped)

        let runs = await runPlane.backgroundRuns()
        #expect(runs.count == 1)
        #expect(runs.first?.completionToken == token)
        #expect(runs.first?.kind == .process)

        // A process kill is certain, so the canceler reports .stopped, and the
        // run plane passes it on as is.
        #expect(await runPlane.cancel(completionToken: token) == .reported(.stopped))

        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: 5)
    }

    @Test("sweep() runs the canceler of a process run and gives the .stopped that the canceler reports")
    func sweepPostsTheProcessCancelerOutcome() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let cancels = Recorder<String>()
        let token = await FakeRun.start(
            on: runPlane, latch: latch, kind: .process, detailOnSettle: "exit 137",
            cancelerOutcome: .stopped, cancels: cancels
        )

        let terminals = await runPlane.sweep()

        // The canceler ran one time, and the terminal event holds its outcome,
        // not a guess of the run plane.
        #expect(cancels.values.count == 1)
        #expect(terminals.count == 1)
        #expect(terminals.first?.correlationID == token)
        #expect(terminals.first?.kind == .completed)
        #expect(terminals.first?.outcome == .stopped)
        #expect(await runPlane.backgroundRuns().isEmpty)

        latch.open()
    }
}
