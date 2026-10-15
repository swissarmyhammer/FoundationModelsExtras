@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises a question in a session with no user. A headless run plane ends
/// each question at once with a cancel that gives
/// ``RunPlane/noUserPresentReason``. The question does not go to the sink as
/// an elicitation event, no question opens, and nothing waits.
///
/// Each test runs the question and a reader of the elicitation events of the
/// sink at the same time, and the first of the two to end decides. A headless
/// run plane ends the question, and no event can come, because the question
/// never goes to the sink. A run plane that sends the question gives the event
/// first, because only an answer ends the question. The test then records an
/// issue and answers the question, thus the test ends and does not wait for a
/// user. No test uses a clock, a sleep, a poll, a retry or a time limit.
@Suite("Run plane: a question in a session with no user ends at once with a cancel")
struct RunPlaneHeadlessQuestionTests {
    private typealias Fixtures = MountFixtures

    /// A sink that keeps each event in a ``MountFixtures/RecordingSink``, and
    /// also gives each elicitation event to ``elicitationPosts``.
    private actor SignallingSink: OperationEventSink {
        /// Keeps each event, in post order.
        let recording = Fixtures.RecordingSink()

        /// Each elicitation event, in post order. The stream ends when
        /// ``endSignals()`` runs.
        let elicitationPosts: AsyncStream<OperationEvent>

        /// Puts each elicitation event into ``elicitationPosts``.
        private let signal: AsyncStream<OperationEvent>.Continuation

        /// Makes a sink with no event.
        init() {
            let (posts, signal) = AsyncStream.makeStream(of: OperationEvent.self)
            self.elicitationPosts = posts
            self.signal = signal
        }

        /// Keeps `event`, and gives it to ``elicitationPosts`` when it is an
        /// elicitation event.
        ///
        /// - Parameter event: The event.
        func post(event: OperationEvent) async {
            await recording.post(event: event)
            guard event.kind == .elicitation else { return }
            signal.yield(event)
        }

        /// Ends ``elicitationPosts``. A reader that waits for an event then
        /// stops.
        nonisolated func endSignals() {
            signal.finish()
        }
    }

    /// What ended first: the question, or the post of its elicitation event.
    private enum FirstEnd: Sendable {
        /// The question ended with this answer.
        case answered(ElicitationResponse)

        /// The question went to the sink as an elicitation event.
        case posted

        /// The sink ended its signals, and no elicitation event came.
        case signalsEnded
    }

    /// A context of the host on `runPlane`, bound to `sink`.
    ///
    /// - Parameters:
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the session.
    ///   - completionToken: The token of the context. A question of the
    ///     context links to it. The default is a new token.
    /// - Returns: The context.
    private static func makeContext(
        on runPlane: RunPlane,
        sink: SignallingSink,
        completionToken: String = RunPlane.makeCompletionToken()
    ) -> ToolContext {
        Fixtures.hostContext(on: runPlane, sink: sink, completionToken: completionToken)
    }

    /// Asks `request` through `context`, and gives the answer.
    ///
    /// The question and a reader of the elicitation events of `sink` run at
    /// the same time. When the question ends first, the reader stops. When an
    /// event comes first, the question went to the sink: the test records an
    /// issue and answers the question with a cancel with no reason, thus the
    /// question ends.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - context: The context that asks.
    ///   - sink: The sink of the context.
    ///   - runPlane: The run plane of the context.
    /// - Returns: The answer that the context got.
    private static func answer(
        to request: ElicitationRequest, through context: ToolContext, sink: SignallingSink, runPlane: RunPlane
    ) async throws -> ElicitationResponse {
        try await withThrowingTaskGroup(of: FirstEnd.self) { group in
            group.addTask { .answered(try await context.elicit(request)) }
            group.addTask { await firstPost(to: sink) }
            var answer: ElicitationResponse?
            for try await end in group {
                switch end {
                case .answered(let response):
                    answer = response
                    sink.endSignals()
                case .posted:
                    Issue.record("the question went to the sink, but no user is present")
                    await runPlane.respond(elicitationId: request.elicitationId, .cancel)
                case .signalsEnded:
                    break
                }
            }
            return try #require(answer)
        }
    }

    /// Waits for the first elicitation event of `sink`.
    ///
    /// - Parameter sink: The sink.
    /// - Returns: ``FirstEnd/posted`` when an event came, or
    ///   ``FirstEnd/signalsEnded`` when the sink ended its signals first.
    private static func firstPost(to sink: SignallingSink) async -> FirstEnd {
        for await _ in sink.elicitationPosts {
            return .posted
        }
        return .signalsEnded
    }

    /// Records an issue when a question went to `sink` or is open on
    /// `runPlane`.
    ///
    /// - Parameters:
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the session.
    private static func expectNoQuestionWasSent(on runPlane: RunPlane, to sink: SignallingSink) async {
        #expect(await sink.recording.events.allSatisfy { $0.kind != .elicitation })
        #expect(await runPlane.pendingElicitationIds().isEmpty)
        #expect(await runPlane.openElicitations().isEmpty)
    }

    // MARK: - The questions of a headless session

    @Test("a headless run plane ends a form question at once with a cancel that gives the reason")
    func aFormQuestionEndsAtOnce() async throws {
        let runPlane = RunPlane(userPresence: .headless)
        let sink = SignallingSink()
        let context = Self.makeContext(on: runPlane, sink: sink)

        let answer = try await Self.answer(
            to: Fixtures.nameRequest(elicitationId: ULID()), through: context, sink: sink, runPlane: runPlane)

        #expect(answer == .cancel(reason: RunPlane.noUserPresentReason))
        await Self.expectNoQuestionWasSent(on: runPlane, to: sink)
    }

    /// A URL question takes the same route. A tool host that relays the
    /// `elicitation/create` request of a downstream MCP server calls
    /// ``ToolContext/elicit(_:)`` with the request of that server, often in
    /// URL mode. Thus in a headless session the server gets the cancel at
    /// once, and no question waits for a user.
    @Test("a headless run plane ends a URL question at once with a cancel that gives the reason")
    func aURLQuestionEndsAtOnce() async throws {
        let runPlane = RunPlane(userPresence: .headless)
        let sink = SignallingSink()
        let context = Self.makeContext(on: runPlane, sink: sink)
        let request = ElicitationRequest(
            message: "Sign in to the server",
            elicitationId: ULID(),
            url: try #require(URL(string: "https://example.com/sign-in"))
        )

        let answer = try await Self.answer(to: request, through: context, sink: sink, runPlane: runPlane)

        #expect(answer == .cancel(reason: RunPlane.noUserPresentReason))
        await Self.expectNoQuestionWasSent(on: runPlane, to: sink)
    }

    @Test("a headless run plane ends the question of a background run at once, and the run does not wait for the user")
    func aQuestionOfABackgroundRunEndsAtOnce() async throws {
        let runPlane = RunPlane(userPresence: .headless)
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch)
        let sink = SignallingSink()
        let context = Self.makeContext(on: runPlane, sink: sink, completionToken: token)

        let answer = try await Self.answer(
            to: Fixtures.nameRequest(elicitationId: ULID()), through: context, sink: sink, runPlane: runPlane)

        #expect(answer == .cancel(reason: RunPlane.noUserPresentReason))
        #expect(await runPlane.backgroundRuns().map(\.completionToken) == [token])
        #expect(await runPlane.runsWaitingOnlyForUser().isEmpty)
        await Self.expectNoQuestionWasSent(on: runPlane, to: sink)

        latch.open()
        _ = await runPlane.wait(completionToken: token, seconds: nil)
    }

    // MARK: - The default

    @Test("a run plane with no stated user presence is interactive")
    func theDefaultIsInteractive() {
        #expect(RunPlane().userPresence == .interactive)
    }

    // MARK: - The user presence through a tool context

    @Test(
        "a tool context gives the user presence of the run plane of its session",
        arguments: [UserPresence.headless, .interactive])
    func aToolContextGivesTheUserPresence(of presence: UserPresence) {
        let context = Self.makeContext(on: RunPlane(userPresence: presence), sink: SignallingSink())

        #expect(context.userPresence == presence)
        // A changed copy of the context is in the same session.
        #expect(context.settling(within: 0).userPresence == presence)
    }
}
