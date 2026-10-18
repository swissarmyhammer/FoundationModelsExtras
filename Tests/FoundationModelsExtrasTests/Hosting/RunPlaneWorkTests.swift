@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the ``WorkKind/backgroundRun`` lease of each background run in
/// the ``WorkRegistry`` of the session: the lease is open from the start of
/// the run to its settle, also on a failure, a cancel and the sweep. While the
/// run waits only for the user, the lease is suspended, and the answer
/// resumes it.
///
/// Each test closes the registry before it reads the transitions, thus the
/// read never hangs. Each wait for a question also ends when the run ends.
@Suite("Run plane: the background work lease of each run")
struct RunPlaneWorkTests {
    private typealias Fixtures = MountFixtures

    /// A run plane over a new registry, and a stream of the transitions of
    /// the registry from the start.
    private struct Plane {
        let registry = WorkRegistry(sessionID: ULID())
        let runPlane: RunPlane
        let transitions: AsyncStream<WorkTransition>

        init() {
            runPlane = RunPlane(workRegistry: registry)
            transitions = registry.transitions()
        }

        /// Closes the registry, and gives each transition of the stream.
        ///
        /// - Returns: The transitions, in order.
        func closeAndCollect() async -> [WorkTransition] {
            registry.close()
            var collected: [WorkTransition] = []
            for await transition in transitions {
                collected.append(transition)
            }
            return collected
        }

        /// The lease of the run of `token`.
        ///
        /// - Parameter token: The completion token of the run.
        /// - Returns: The open item.
        func item(of token: String) -> WorkItem {
            WorkItem(kind: .backgroundRun, id: token, sessionID: registry.sessionID)
        }
    }

    /// Starts a run on `plane` whose body asks each of `requests` at the
    /// same time, then succeeds. Waits until each question is posted, or
    /// until the run settles first.
    ///
    /// - Parameters:
    ///   - plane: The run plane.
    ///   - requests: The questions that the body asks.
    /// - Returns: The completion token of the run.
    private static func startAskingRun(on plane: Plane, asking requests: [ElicitationRequest]) async -> String {
        let token = RunPlane.makeCompletionToken()
        let posts = requests.map { _ in RunLatch() }
        let runPlane = plane.runPlane
        await runPlane.start(
            tool: FakeRun.tool, op: FakeRun.op, kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            await withTaskGroup(of: Void.self) { group in
                for (request, posted) in zip(requests, posts) {
                    group.addTask {
                        _ = await runPlane.awaitAnswer(to: request, runToken: token) { posted.open() }
                    }
                }
            }
            return FakeRun.terminalEvent(token: token, outcome: .succeeded)
        }
        await Waits.untilFirstEnds(
            {
                for posted in posts { await posted.waitUntilOpen() }
            },
            { _ = await runPlane.wait(completionToken: token, seconds: nil) })
        return token
    }

    // MARK: - Start to settle

    @Test("a run holds its lease from the start to the settle")
    func aRunHoldsItsLeaseToTheSettle() async {
        let plane = Plane()
        let latch = RunLatch()

        let token = await FakeRun.start(on: plane.runPlane, latch: latch)
        #expect(plane.registry.openWork == [plane.item(of: token)])
        latch.open()
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(!plane.registry.hasWork)
        #expect(await plane.closeAndCollect() == [.workStarted, .noWork])
    }

    @Test("a run that fails ends its lease at its settle")
    func aFailedRunEndsItsLease() async {
        let plane = Plane()
        let token = RunPlane.makeCompletionToken()
        let latch = RunLatch()
        await plane.runPlane.start(
            tool: FakeRun.tool, op: FakeRun.op, kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            await latch.waitUntilOpen()
            return FakeRun.terminalEvent(token: token, outcome: .failed)
        }
        #expect(plane.registry.hasWork)

        latch.open()
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(!plane.registry.hasWork)
        #expect(await plane.closeAndCollect() == [.workStarted, .noWork])
    }

    @Test("a mounted background call that throws holds the session until its run settles")
    func aThrowingBackgroundCallEndsItsLease() async throws {
        let plane = Plane()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.ThrowingTool(), runPlane: plane.runPlane)

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let token = try Fixtures.decodeEnvelope(rendered).completionToken
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(!plane.registry.hasWork)
        #expect(await plane.closeAndCollect() == [.workStarted, .noWork])
    }

    @Test("a cancel of a run ends its lease when the run settles")
    func aCancelledRunEndsItsLease() async {
        let plane = Plane()
        let token = await FakeRun.start(on: plane.runPlane, latch: RunLatch())

        _ = await plane.runPlane.cancel(completionToken: token)
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(!plane.registry.hasWork)
        #expect(await plane.closeAndCollect() == [.workStarted, .noWork])
    }

    @Test("the sweep ends the lease of each run, also of a run whose body continues")
    func theSweepEndsEachLease() async {
        let plane = Plane()
        let latch = RunLatch()
        _ = await FakeRun.start(on: plane.runPlane, latch: latch, kind: .process, cancelerOutcome: .stopped)
        _ = await FakeRun.start(on: plane.runPlane, latch: RunLatch())
        #expect(plane.registry.openWork.count == 2)

        _ = await plane.runPlane.sweep()

        #expect(!plane.registry.hasWork)
        latch.open()
        await plane.runPlane.joinRunBodies()
        #expect(await plane.closeAndCollect() == [.workStarted, .noWork])
    }

    // MARK: - The wait for the user

    @Test("a run that waits only for the user is not work, and the answer makes it work again")
    func aRunThatWaitsOnlyForTheUserIsNotWork() async {
        let plane = Plane()
        let request = Fixtures.nameRequest()

        let token = await Self.startAskingRun(on: plane, asking: [request])
        #expect(await plane.runPlane.runsWaitingOnlyForUser().map(\.completionToken) == [token])
        #expect(await plane.runPlane.backgroundRuns().map(\.completionToken) == [token])
        #expect(!plane.registry.hasWork)

        #expect(await plane.runPlane.respond(elicitationId: request.elicitationId, .decline) == .delivered)
        #expect(plane.registry.openWork == [plane.item(of: token)])
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(!plane.registry.hasWork)
        #expect(await plane.closeAndCollect() == [.workStarted, .noWork, .workStarted, .noWork])
    }

    @Test("a run with two open questions is work again only when both left the open list")
    func aRunWithTwoQuestionsResumesAfterBoth() async {
        let plane = Plane()
        let first = Fixtures.nameRequest()
        let second = Fixtures.nameRequest()

        let token = await Self.startAskingRun(on: plane, asking: [first, second])
        #expect(!plane.registry.hasWork)
        await plane.runPlane.respond(elicitationId: first.elicitationId, .decline)
        #expect(!plane.registry.hasWork)
        await plane.runPlane.respond(elicitationId: second.elicitationId, .decline)
        #expect(plane.registry.hasWork)
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(await plane.closeAndCollect() == [.workStarted, .noWork, .workStarted, .noWork])
    }

    @Test("a run whose question the host ends is work again, and settles")
    func aRunWhoseQuestionEndsIsWorkAgain() async {
        let plane = Plane()
        let request = Fixtures.nameRequest()

        let token = await Self.startAskingRun(on: plane, asking: [request])
        #expect(!plane.registry.hasWork)
        _ = await plane.runPlane.cancelOpenElicitations()
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(!plane.registry.hasWork)
        #expect(await plane.closeAndCollect() == [.workStarted, .noWork, .workStarted, .noWork])
    }

    @Test("an accepted URL question still waits for the user until its completion")
    func anAcceptedURLQuestionWaitsUntilItsCompletion() async throws {
        let plane = Plane()
        let request = try Fixtures.urlRequest()

        let token = await Self.startAskingRun(on: plane, asking: [request])
        #expect(await plane.runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(!plane.registry.hasWork)
        #expect(await plane.runPlane.complete(elicitationId: request.elicitationId) == .completed)
        #expect(plane.registry.hasWork)
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(await plane.closeAndCollect() == [.workStarted, .noWork, .workStarted, .noWork])
    }

    @Test("a question of a token that is not a run takes no lease and changes no lease")
    func aQuestionOfAForeignTokenChangesNoLease() async throws {
        let plane = Plane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: plane.runPlane, latch: latch)

        let question = await QuestionTask.ask(
            Fixtures.nameRequest(), runToken: RunPlane.makeCompletionToken(), on: plane.runPlane)
        #expect(plane.registry.openWork == [plane.item(of: token)])
        await plane.runPlane.respond(elicitationId: question.elicitationId, .decline)
        _ = try await question.answer(on: plane.runPlane)
        latch.open()
        _ = await plane.runPlane.wait(completionToken: token, seconds: nil)

        #expect(await plane.closeAndCollect() == [.workStarted, .noWork])
    }
}
