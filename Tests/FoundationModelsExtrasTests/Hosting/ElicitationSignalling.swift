import FoundationModelsExtras
import ULID

/// What a ``SignallingSink`` got, in the order that it got it.
enum ElicitationSignal: Hashable, Sendable {
    /// The elicitation event of the question with this id.
    case asked(ULID)

    /// The end of the accepted URL flow of the question with this id.
    case completed(ULID)

    /// The sink got the end of the accepted URL flow of the question with
    /// this id, and holds it until its completion gate opens. Only a sink
    /// with a completion gate sends it.
    case completionHeld(ULID)

    /// The end of the question with this id that the run plane cancelled,
    /// with the reason of the answer that the run gets.
    case ended(ULID, reason: String?)

    /// The sink got the end of the question with this id, and holds it until
    /// its end gate opens. Only a sink with an end gate sends it.
    case endHeld(ULID)

    /// A progress event with this detail.
    case progress(String)
}

/// A sink that sends each question, each completion of a URL flow and each
/// end of a question to one stream.
///
/// The stream ends when the sink is released. A test gives the sink only to
/// the tasks that ask, so the stream ends when each of those tasks and each
/// open question has ended. A reader that waits for a signal that never comes
/// then reads the end of the stream, and the test fails and does not hang.
///
/// A sink with a completion gate holds each completion until the gate opens.
/// It sends ``ElicitationSignal/completionHeld(_:)`` first, and
/// ``ElicitationSignal/completed(_:)`` after the gate opens. A progress event
/// also opens the gate, thus a run that posts while the sink holds a
/// completion releases it, and the stream gets both signals.
///
/// A sink with an end gate holds each end of a question in the same way. It
/// sends ``ElicitationSignal/endHeld(_:)`` first, and
/// ``ElicitationSignal/ended(_:reason:)`` after the gate opens. A progress
/// event also opens the end gate.
///
/// The sink uses only the public API, so a file with a plain import can use
/// it.
actor SignallingSink: OperationEventSink {
    /// Each signal, in the order that the sink got it.
    nonisolated let signals: AsyncStream<ElicitationSignal>

    /// Adds a signal to ``signals``.
    private let continuation: AsyncStream<ElicitationSignal>.Continuation

    /// The gate that each completion waits for, or `nil` for no wait.
    private let completionGate: RunLatch?

    /// The gate that each end of a question waits for, or `nil` for no wait.
    private let endGate: RunLatch?

    /// Makes a sink with an empty stream.
    ///
    /// - Parameters:
    ///   - completionGate: The gate that each completion waits for, or `nil`
    ///     to send each completion at once. The default is `nil`.
    ///   - endGate: The gate that each end of a question waits for, or `nil`
    ///     to send each end at once. The default is `nil`.
    init(completionGate: RunLatch? = nil, endGate: RunLatch? = nil) {
        (signals, continuation) = AsyncStream.makeStream()
        self.completionGate = completionGate
        self.endGate = endGate
    }

    deinit {
        continuation.finish()
    }

    /// Sends the id of the question of `event`, when `event` asks one, and
    /// the detail of `event`, when it is a progress event. A progress event
    /// opens the completion gate and the end gate.
    ///
    /// - Parameter event: The event.
    func post(event: OperationEvent) {
        if let request = event.elicitation {
            continuation.yield(.asked(request.elicitationId))
        }
        guard event.kind == .progress else { return }
        continuation.yield(.progress(event.detail))
        completionGate?.open()
        endGate?.open()
    }

    /// Sends the id of the question that ended, with the reason of its
    /// answer. With an end gate, sends that the sink holds the end, then
    /// waits for the gate before it sends the end.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - response: The answer that the run of the question gets.
    func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) async {
        if let endGate {
            continuation.yield(.endHeld(elicitationId))
            await endGate.waitUntilOpen()
        }
        continuation.yield(.ended(elicitationId, reason: response.reason))
    }

    /// Sends the id of the question whose URL flow completed. With a
    /// completion gate, sends that the sink holds the completion, then waits
    /// for the gate before it sends the completion.
    ///
    /// - Parameter elicitationId: The id of the question.
    func post(elicitationCompleted elicitationId: ULID) async {
        if let completionGate {
            continuation.yield(.completionHeld(elicitationId))
            await completionGate.waitUntilOpen()
        }
        continuation.yield(.completed(elicitationId))
    }
}

/// The questions of one test, and the stream of the sink that they post to.
struct Asking {
    /// The stream of the sink.
    let signals: AsyncStream<ElicitationSignal>

    /// The answer of each question, in the order of the requests.
    let answers: [Task<ElicitationResponse, any Error>]

    /// Asks each of `requests` at once, and each of `gatedRequests` after
    /// `gate` opens. Each question has its own host context, and all post to
    /// one new ``SignallingSink``. Only the tasks hold the sink, thus the
    /// stream ends when each task has ended.
    ///
    /// - Parameters:
    ///   - requests: The questions to ask at once.
    ///   - runPlane: The run plane of the session.
    ///   - gatedRequests: The questions to ask after `gate` opens.
    ///   - gate: The gate of `gatedRequests`.
    ///   - completionGate: The completion gate of the sink, or `nil`.
    ///   - endGate: The end gate of the sink, or `nil`.
    /// - Returns: The stream of the sink and the answers, first `requests`,
    ///   then `gatedRequests`.
    static func start(
        _ requests: [ElicitationRequest],
        on runPlane: RunPlane,
        gatedRequests: [ElicitationRequest] = [],
        gate: RunLatch = RunLatch.closed(),
        completionGate: RunLatch? = nil,
        endGate: RunLatch? = nil
    ) -> Asking {
        let sink = SignallingSink(completionGate: completionGate, endGate: endGate)
        let answers =
            requests.map { askingTask($0, on: runPlane, sink: sink, after: nil) }
            + gatedRequests.map { askingTask($0, on: runPlane, sink: sink, after: gate) }
        return Asking(signals: sink.signals, answers: answers)
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
            return try await MountFixtures.hostContext(on: runPlane, sink: sink).elicit(request)
        }
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

    /// The id of each end of a question that the reader read, in order.
    var ends: [ULID] {
        history.compactMap { signal in
            guard case .ended(let elicitationId, _) = signal else { return nil }
            return elicitationId
        }
    }

    /// Tells if the reader read `earlier`, and read it before `later`.
    ///
    /// - Parameters:
    ///   - earlier: The signal that must come first.
    ///   - later: The signal that must come after `earlier`.
    /// - Returns: `true` when ``history`` holds both, `earlier` first.
    func read(_ earlier: ElicitationSignal, before later: ElicitationSignal) -> Bool {
        guard let first = history.firstIndex(of: earlier), let second = history.firstIndex(of: later) else {
            return false
        }
        return first < second
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

    /// Reads until it reads the elicitation event of a question, and keeps
    /// each signal that it read.
    ///
    /// - Returns: The id of the question, or `nil` when the stream ends
    ///   first.
    mutating func nextAskedId() async -> ULID? {
        while let signal = await iterator.next() {
            history.append(signal)
            if case .asked(let elicitationId) = signal {
                return elicitationId
            }
        }
        return nil
    }
}
