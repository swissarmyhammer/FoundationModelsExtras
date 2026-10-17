/// A gate that stays closed until one task opens it, and then stays open.
///
/// A test holds work that must take time behind a latch, and opens the
/// latch at the event that it waits for. A task can also open a latch to
/// signal an event. A wait ends when the latch opens, or when the waiting
/// task is cancelled. The latch reads no clock.
final class Latch: Sendable {
    /// One record for each open. Only the first one is important.
    private let opens = EventLog<Void>()

    /// Whether a task opened the latch.
    var isOpen: Bool {
        !opens.recorded.isEmpty
    }

    /// Opens the latch, and lets each waiting task continue. A second open
    /// does nothing more. A caller that cannot wait, such as a callback or a
    /// cancellation handler, can call this function.
    func open() {
        opens.record(())
    }

    /// Waits until the latch is open, or until the task is cancelled.
    /// Returns at once when the latch is open now.
    func waitUntilOpen() async {
        await opens.waitUntil { !$0.isEmpty }
    }
}
