/// A first-in, first-out chain of asynchronous deliveries.
///
/// ``enqueue(body:)`` does not suspend, so an actor that keeps the chain in
/// its own state fixes the place of each delivery when it calls the method.
/// A delivery starts only after each earlier delivery ends.
public struct SerialAsyncChain: Sendable {
    /// The last delivery that was enqueued, or `nil` before the first one.
    private var tail: Task<Void, Never>?

    /// Makes an empty chain.
    public init() {}

    /// Adds `body` behind each delivery that is already in the chain.
    ///
    /// - Parameter body: The delivery. It starts after each earlier one ends.
    /// - Returns: The task of the delivery, for a caller that waits for it.
    public mutating func enqueue(body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let delivery = Task {
            await previous?.value
            await body()
        }
        tail = delivery
        return delivery
    }
}
