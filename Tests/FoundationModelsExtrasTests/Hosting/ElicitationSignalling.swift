import FoundationModelsExtras
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
///
/// The sink uses only the public API, so a file with a plain import can use
/// it.
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
