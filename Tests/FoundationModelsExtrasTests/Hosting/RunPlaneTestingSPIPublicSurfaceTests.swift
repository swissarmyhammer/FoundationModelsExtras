import Foundation
@_spi(Testing) import FoundationModelsExtras
import Testing

/// Holds ``RunPlane/start(tool:op:kind:completionToken:canceler:tracer:body:)``,
/// ``RunPlane/StartResult``, ``RunPlane/updateProgress(completionToken:detail:)``
/// and ``RunPlane/wait(completionToken:seconds:)`` to the `Testing` SPI. A test
/// outside this package starts a run, updates its progress and waits for it
/// directly on the run plane.
///
/// The import has `@_spi(Testing)`, with no `@testable`. When one of these
/// loses its access level, this file does not compile. That is the assertion
/// that matters, because the caller is in another package, where `@testable`
/// is not available.
@Suite("RunPlane start, updateProgress and wait over the Testing SPI", .timeLimit(.minutes(1)))
struct RunPlaneTestingSPIPublicSurfaceTests {
    /// Starts a run on `runPlane` that waits on `latch`, then returns a
    /// terminal event with `detail`.
    ///
    /// - Parameters:
    ///   - runPlane: The run plane that tracks the run.
    ///   - token: The completion token of the run.
    ///   - latch: The latch that the body waits on.
    ///   - detail: The detail of the terminal event.
    /// - Returns: What the start did.
    @discardableResult
    private static func startGatedRun(
        on runPlane: RunPlane,
        token: String,
        latch: RunLatch,
        detail: String
    ) async -> RunPlane.StartResult {
        await runPlane.start(
            tool: FakeRun.tool,
            op: FakeRun.op,
            kind: .swiftTask,
            completionToken: token,
            canceler: nil,
            body: {
                await latch.waitUntilOpen()
                return FakeRun.terminalEvent(token: token, outcome: .succeeded, detail: detail)
            }
        )
    }

    @Test("a started run shows its progress, and a wait gets its terminal event when it settles")
    func aStartedRunShowsProgressAndSettles() async {
        let runPlane = RunPlane()
        let latch = RunLatch.closed()
        let token = RunPlane.makeCompletionToken()

        let started = await Self.startGatedRun(on: runPlane, token: token, latch: latch, detail: "done")
        await runPlane.updateProgress(completionToken: token, detail: "half")

        #expect(started == .started)
        #expect(await runPlane.backgroundRuns().map(\.latestProgressDetail) == ["half"])
        #expect(await runPlane.wait(completionToken: token, seconds: 0) == .deadlineElapsed)

        latch.open()
        let outcome = await runPlane.wait(completionToken: token, seconds: nil)

        #expect(outcome == .settled(FakeRun.terminalEvent(token: token, outcome: .succeeded, detail: "done")))
    }

    @Test("a start with a token that names a run does not start a second run")
    func aStartWithATrackedTokenIsADuplicate() async {
        let runPlane = RunPlane()
        let latch = RunLatch.closed()
        let token = RunPlane.makeCompletionToken()
        await Self.startGatedRun(on: runPlane, token: token, latch: latch, detail: "first")

        let second = await Self.startGatedRun(on: runPlane, token: token, latch: latch, detail: "second")
        latch.open()

        #expect(second == .duplicateToken)
        let firstTerminal = FakeRun.terminalEvent(token: token, outcome: .succeeded, detail: "first")
        #expect(await runPlane.wait(completionToken: token, seconds: nil) == .settled(firstTerminal))
    }
}
