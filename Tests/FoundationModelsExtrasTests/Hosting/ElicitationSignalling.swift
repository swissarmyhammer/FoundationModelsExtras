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

    /// A progress event with this detail.
    case progress(String)
}

/// A sink that sends each question and each completion of a URL flow to one
/// stream.
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
/// The sink uses only the public API, so a file with a plain import can use
/// it.
actor SignallingSink: OperationEventSink {
    /// Each signal, in the order that the sink got it.
    nonisolated let signals: AsyncStream<ElicitationSignal>

    /// Adds a signal to ``signals``.
    private let continuation: AsyncStream<ElicitationSignal>.Continuation

    /// The gate that each completion waits for, or `nil` for no wait.
    private let completionGate: RunLatch?

    /// Makes a sink with an empty stream.
    ///
    /// - Parameter completionGate: The gate that each completion waits for,
    ///   or `nil` to send each completion at once. The default is `nil`.
    init(completionGate: RunLatch? = nil) {
        (signals, continuation) = AsyncStream.makeStream()
        self.completionGate = completionGate
    }

    deinit {
        continuation.finish()
    }

    /// Sends the id of the question of `event`, when `event` asks one, and
    /// the detail of `event`, when it is a progress event. A progress event
    /// opens the completion gate.
    ///
    /// - Parameter event: The event.
    func post(event: OperationEvent) {
        if let request = event.elicitation {
            continuation.yield(.asked(request.elicitationId))
        }
        guard event.kind == .progress else { return }
        continuation.yield(.progress(event.detail))
        completionGate?.open()
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
