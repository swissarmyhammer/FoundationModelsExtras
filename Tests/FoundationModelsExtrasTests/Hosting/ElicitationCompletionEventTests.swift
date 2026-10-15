@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// What a ``SignallingSink`` got, in the order that it got it.
enum ElicitationSignal: Hashable, Sendable {
    /// The elicitation event of the question with this id.
    case asked(ULID)

    /// The end of the accepted URL flow of the question with this id.
    case completed(ULID)
}

/// A sink that sends each question and each completion of a URL flow to one
/// stream.
///
/// The stream ends when the sink is released. A test gives the sink only to
/// the tasks that ask, so the stream ends when each of those tasks and each
/// open question has ended. A reader that waits for a signal that never comes
/// then reads the end of the stream, and the test fails and does not hang.
actor SignallingSink: OperationEventSink {
    /// Each signal, in the order that the sink got it.
    nonisolated let signals: AsyncStream<ElicitationSignal>

    /// Adds a signal to ``signals``.
    private let continuation: AsyncStream<ElicitationSignal>.Continuation

    /// Makes a sink with an empty stream.
    init() {
        (signals, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    /// Sends the id of the question of `event`, when `event` asks one.
    ///
    /// - Parameter event: The event.
    func post(event: OperationEvent) {
        guard let request = event.elicitation else { return }
        continuation.yield(.asked(request.elicitationId))
    }

    /// Sends the id of the question whose URL flow completed.
    ///
    /// - Parameter elicitationId: The id of the question.
    func post(elicitationCompleted elicitationId: ULID) {
        continuation.yield(.completed(elicitationId))
    }
}

/// Reads the signals of one ``SignallingSink`` in order, and keeps each
/// signal that it read.
struct SignalReader {
    /// The next signal of the stream.
    private var iterator: AsyncStream<ElicitationSignal>.Iterator

    /// Each signal that the reader read, in order.
    private(set) var history: [ElicitationSignal] = []

    /// The id of each completion that the reader read, in order.
    var completions: [ULID] {
        history.compactMap { signal in
            guard case .completed(let elicitationId) = signal else { return nil }
            return elicitationId
        }
    }

    /// Makes a reader of `signals`.
    ///
    /// - Parameter signals: The stream of the sink.
    init(_ signals: AsyncStream<ElicitationSignal>) {
        iterator = signals.makeAsyncIterator()
    }

    /// Reads until ``history`` holds each signal of `expected`, or until the
    /// stream ends.
    ///
    /// - Parameter expected: The signals to wait for.
    mutating func wait(for expected: Set<ElicitationSignal>) async {
        while !expected.isSubset(of: history) {
            guard let signal = await iterator.next() else { return }
            history.append(signal)
        }
    }
}

/// Exercises the completion event of a URL flow: the run plane tells the sink
/// of the question through ``OperationEventSink/post(elicitationCompleted:)``
/// when an accepted URL flow completes, and at no other end of a question. A
/// tool ends its own accepted flow with
/// ``ToolContext/complete(elicitationId:)``.
///
/// Each wait reads a stream of events. No test reads a clock or sleeps. To
/// show that an end of a question posts no completion, a test completes a
/// second flow after it, waits for that completion, and then reads each
/// completion that came.
@Suite("Run plane: the completion event of a URL flow")
struct ElicitationCompletionEventTests {
    /// The value of each mounted call.
    private static let callValue = "x"

    /// The questions of one test, and the stream of the sink that they post
    /// to.
    private struct Asking {
        /// The stream of the sink.
        let signals: AsyncStream<ElicitationSignal>

        /// The answer of each question, in the order of the requests.
        let answers: [Task<ElicitationResponse, any Error>]
    }

    /// Asks one question with `request`, then returns the action of the
    /// answer.
    private struct AskingTool: Tool {
        let name = "asking_tool"
        let description = "asks one question, then returns the action of the answer"
        let request: ElicitationRequest

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await context.elicit(request).action.rawValue
        }
    }

    /// Mounts an ``AskingTool`` in a synchronous mount through its own
    /// context, and calls it.
    private struct MountingAskingTool: Tool {
        let name = "mounting_asking_tool"
        let description = "mounts a tool that asks one question, and calls it"
        let request: ElicitationRequest

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await context.mount(AskingTool(request: request)).call(arguments: arguments)
        }
    }

    // MARK: - Helpers

    /// A URL question with a new id.
    ///
    /// - Returns: The question.
    /// - Throws: When the URL does not parse.
    private static func urlRequest() throws -> ElicitationRequest {
        ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: try #require(URL(string: "https://example.com/sign-in")))
    }

    /// A context that a host makes on `runPlane`. It is a run of its own,
    /// with a new completion token.
    ///
    /// - Parameters:
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the context.
    /// - Returns: The context.
    private static func hostContext(on runPlane: RunPlane, sink: any OperationEventSink) -> ToolContext {
        ToolContext(
            sessionID: ULID(), runPlane: runPlane, sink: sink, tool: "host_tool", op: "ask user",
            completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
    }

    /// Starts one task that asks `request` through a new host context on
    /// `runPlane`, after `gate` opens.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the context.
    ///   - gate: The gate to wait for, or `nil` to ask at once.
    /// - Returns: The task, which gives the answer.
    private static func askingTask(
        _ request: ElicitationRequest, on runPlane: RunPlane, sink: SignallingSink, after gate: RunLatch?
    ) -> Task<ElicitationResponse, any Error> {
        Task {
            await gate?.waitUntilOpen()
            return try await hostContext(on: runPlane, sink: sink).elicit(request)
        }
    }

    /// Asks each of `requests` at once, and each of `gatedRequests` after
    /// `gate` opens. Each question has its own host context, and all post to
    /// one new ``SignallingSink``. Only the tasks hold the sink.
    ///
    /// - Parameters:
    ///   - requests: The questions to ask at once.
    ///   - runPlane: The run plane of the session.
    ///   - gatedRequests: The questions to ask after `gate` opens.
    ///   - gate: The gate of `gatedRequests`.
    /// - Returns: The stream of the sink and the answers, first `requests`,
    ///   then `gatedRequests`.
    private static func ask(
        _ requests: [ElicitationRequest],
        on runPlane: RunPlane,
        gatedRequests: [ElicitationRequest] = [],
        gate: RunLatch = RunLatch.closed()
    ) -> Asking {
        let sink = SignallingSink()
        let answers =
            requests.map { askingTask($0, on: runPlane, sink: sink, after: nil) }
            + gatedRequests.map { askingTask($0, on: runPlane, sink: sink, after: gate) }
        return Asking(signals: sink.signals, answers: answers)
    }

    /// Mounts `tool` in a synchronous mount on a new site of `runPlane` that
    /// posts to a new ``SignallingSink``, and starts one call. Only the call
    /// holds the sink.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - runPlane: The run plane of the session.
    /// - Returns: The stream of the sink, and the task of the call.
    /// - Throws: When the mounted tool does not keep the types of `tool`.
    private static func call(
        _ tool: any Tool, mountedOn runPlane: RunPlane
    ) throws -> (signals: AsyncStream<ElicitationSignal>, calling: Task<String, any Error>) {
        let sink = SignallingSink()
        let site = MountFixtures.site(runPlane: runPlane, sink: sink)
        let mounted = try #require(
            ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous)
                as? any Tool<MountArguments, String>)
        return (sink.signals, Task { try await mounted.call(arguments: MountArguments(value: callValue)) })
    }

    /// Accepts the URL question of `elicitationId` and completes its flow, as
    /// a host does.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - runPlane: The run plane of the session.
    private static func acceptAndComplete(_ elicitationId: ULID, on runPlane: RunPlane) async {
        #expect(await runPlane.respond(elicitationId: elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(await runPlane.complete(elicitationId: elicitationId) == .completed)
    }

    /// Asks `request` and a second URL question, ends `request` with
    /// `answer`, then completes the flow of the second question. Expects
    /// that the run of `request` gets `delivered`, and that the only
    /// completion is the one of the second question.
    ///
    /// - Parameters:
    ///   - request: The question that `answer` ends.
    ///   - answer: The answer of the host.
    ///   - delivered: The answer that the run of `request` gets.
    /// - Throws: When a task of a question throws.
    private static func expectNoCompletion(
        after answer: ElicitationResponse, to request: ElicitationRequest, delivers delivered: ElicitationResponse
    ) async throws {
        let runPlane = RunPlane()
        let later = try urlRequest()
        let asking = ask([request, later], on: runPlane)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(request.elicitationId), .asked(later.elicitationId)])

        #expect(await runPlane.respond(elicitationId: request.elicitationId, answer) == .delivered)
        #expect(try await asking.answers[0].value == delivered)
        await acceptAndComplete(later.elicitationId, on: runPlane)
        await reader.wait(for: [.completed(later.elicitationId)])

        #expect(reader.completions == [later.elicitationId])
    }

    // MARK: - The completion by the host

    @Test("a host completion of an accepted URL flow posts one completion with its id, and the run gets the accept")
    func aHostCompletionPostsOneCompletion() async throws {
        let runPlane = RunPlane()
        let first = try Self.urlRequest()
        let second = try Self.urlRequest()
        let asking = Self.ask([first, second], on: runPlane)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(first.elicitationId), .asked(second.elicitationId)])

        await Self.acceptAndComplete(first.elicitationId, on: runPlane)
        #expect(try await asking.answers[0].value == .accept(content: nil))
        await Self.acceptAndComplete(second.elicitationId, on: runPlane)
        await reader.wait(for: [.completed(first.elicitationId), .completed(second.elicitationId)])

        #expect(reader.completions.count == 2)
        #expect(Set(reader.completions) == [first.elicitationId, second.elicitationId])
    }

    // MARK: - The ends that post no completion

    @Test("a decline of a URL question posts no completion")
    func aDeclinePostsNoCompletion() async throws {
        let request = try Self.urlRequest()

        try await Self.expectNoCompletion(after: .decline, to: request, delivers: .decline)
    }

    @Test("a cancel of a URL question posts no completion")
    func aCancelPostsNoCompletion() async throws {
        let request = try Self.urlRequest()

        try await Self.expectNoCompletion(after: .cancel, to: request, delivers: .cancel)
    }

    @Test("an accept of a form question posts no completion")
    func aFormAcceptPostsNoCompletion() async throws {
        let answer = ElicitationResponse.accept(content: ["name": .string("Ada")])

        try await Self.expectNoCompletion(after: answer, to: MountFixtures.nameRequest(), delivers: answer)
    }

    @Test("the sweep of an accepted URL question that waits for its completion posts no completion")
    func theSweepPostsNoCompletion() async throws {
        let runPlane = RunPlane()
        let swept = try Self.urlRequest()
        let later = try Self.urlRequest()
        let gate = RunLatch.closed()
        let asking = Self.ask([swept], on: runPlane, gatedRequests: [later], gate: gate)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(swept.elicitationId)])
        #expect(await runPlane.respond(elicitationId: swept.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        #expect(await runPlane.sweep().isEmpty)
        #expect(try await asking.answers[0].value == .cancel(reason: RunPlane.runCancelledReason))
        gate.open()
        await reader.wait(for: [.asked(later.elicitationId)])
        await Self.acceptAndComplete(later.elicitationId, on: runPlane)
        await reader.wait(for: [.completed(later.elicitationId)])

        #expect(reader.completions == [later.elicitationId])
    }

    // MARK: - The completion by the tool

    @Test("a second task of the tool ends its own accepted URL flow, the run gets the accept, and one completion is posted")
    func aToolEndsItsOwnAcceptedFlow() async throws {
        let runPlane = RunPlane()
        let sink = SignallingSink()
        var reader = SignalReader(sink.signals)
        let context = Self.hostContext(on: runPlane, sink: sink)
        let first = try Self.urlRequest()
        let second = try Self.urlRequest()
        let askingFirst = Task { try await context.elicit(first) }
        await reader.wait(for: [.asked(first.elicitationId)])
        #expect(await runPlane.respond(elicitationId: first.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        let delivery = await Task { await context.complete(elicitationId: first.elicitationId) }.value
        try #require(delivery == .completed)
        #expect(try await askingFirst.value == .accept(content: nil))
        let askingSecond = Task { try await context.elicit(second) }
        await reader.wait(for: [.asked(second.elicitationId)])
        #expect(await runPlane.respond(elicitationId: second.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(await context.complete(elicitationId: second.elicitationId) == .completed)
        #expect(try await askingSecond.value == .accept(content: nil))
        await reader.wait(for: [.completed(first.elicitationId), .completed(second.elicitationId)])

        #expect(reader.completions.count == 2)
        #expect(Set(reader.completions) == [first.elicitationId, second.elicitationId])
    }

    @Test("a context does not end the accepted URL flow of a question of another run")
    func aContextDoesNotEndTheFlowOfAnotherRun() async throws {
        let runPlane = RunPlane()
        let sink = SignallingSink()
        var reader = SignalReader(sink.signals)
        let asker = Self.hostContext(on: runPlane, sink: sink)
        let other = Self.hostContext(on: runPlane, sink: sink)
        let request = try Self.urlRequest()
        let asking = Task { try await asker.elicit(request) }
        await reader.wait(for: [.asked(request.elicitationId)])
        #expect(await runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        #expect(await other.complete(elicitationId: request.elicitationId) == .noPendingElicitation)
        #expect(
            await runPlane.openElicitations()
                == [OpenElicitation(elicitationId: request.elicitationId, runToken: asker.completionToken)])
        try #require(await asker.complete(elicitationId: request.elicitationId) == .completed)
        #expect(try await asking.value == .accept(content: nil))
        await reader.wait(for: [.completed(request.elicitationId)])

        #expect(reader.completions == [request.elicitationId])
    }

    // MARK: - A nested mount

    @Test("the completion of a question that a nested synchronous mount asked reaches the sink of the session")
    func theCompletionOfANestedQuestionReachesTheSessionSink() async throws {
        let runPlane = RunPlane()
        let request = try Self.urlRequest()
        let mounted = try Self.call(MountingAskingTool(request: request), mountedOn: runPlane)
        var reader = SignalReader(mounted.signals)
        await reader.wait(for: [.asked(request.elicitationId)])

        await Self.acceptAndComplete(request.elicitationId, on: runPlane)
        #expect(try await mounted.calling.value == ElicitationResponse.Action.accept.rawValue)
        await reader.wait(for: [.completed(request.elicitationId)])

        #expect(reader.completions == [request.elicitationId])
    }
}
