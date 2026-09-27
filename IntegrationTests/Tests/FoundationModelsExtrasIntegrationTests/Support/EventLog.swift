/// A list of events that concurrent tasks append to, in the order of arrival.
///
/// An actor keeps the list, thus a test needs no lock of its own.
actor EventLog<Event: Sendable> {
    /// The events, first in first.
    private(set) var events: [Event] = []

    /// Adds `event` at the end of the list.
    ///
    /// - Parameter event: The event that occurred.
    func append(_ event: Event) {
        events.append(event)
    }
}
